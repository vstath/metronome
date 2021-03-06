-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Kim Alvefur, Florian Zeitz, Marco Cirillo, Matthew Wild, Paul Aurich, Waqas Hussain

local hosts = metronome.hosts;
local incoming = metronome.incoming_s2s;
local host_session = hosts[module.host];
local s2s_make_authenticated = require "core.s2smanager".make_authenticated;

local log = module._log;
local s2s_strict_mode = module:get_option_boolean("s2s_strict_mode", false);
local require_encryption = module:get_option_boolean("s2s_require_encryption", false);

local st = require "util.stanza";
local sha256_hash = require "util.hashes".sha256;
local nameprep = require "util.encodings".stringprep.nameprep;

local xmlns_db = "jabber:server:dialback";
local xmlns_starttls = "urn:ietf:params:xml:ns:xmpp-tls";
local xmlns_stream = "http://etherx.jabber.org/streams";
local xmlns_stanzas = "urn:ietf:params:xml:ns:xmpp-stanzas";

local dialback_requests = setmetatable({}, { __mode = "v" });

function generate_dialback(id, to, from)
	if hosts[from] then
		return sha256_hash(id..to..from..hosts[from].dialback_secret, true);
	else
		return false;
	end
end

function initiate_dialback(session)
	session.dialback_key = generate_dialback(session.streamid, session.to_host, session.from_host);
	session.sends2s(st.stanza("db:result", { from = session.from_host, to = session.to_host }):text(session.dialback_key));
	session.log("info", "sent dialback key on outgoing s2s stream");
end

function verify_dialback(id, to, from, key)
	return key == generate_dialback(id, to, from);
end

function make_authenticated(session, host)
	if require_encryption and not session.secure then
		local t = session.direction == "outgoing" and "offered" or "used";
		session:close({ condition = "policy-violation", text = "TLS encryption is mandatory but wasn't "..t }, "authentication failure");
		return false;
	end
	if session.type == "s2sout_unauthed" then
		local multiplexed_from = session.multiplexed_from;
		if multiplexed_from and not multiplexed_from.destroyed then
			local hosts = multiplexed_from.hosts;
			if not hosts[session.to_host] then
				hosts[session.to_host] = { authed = true };
			else
				hosts[session.to_host].authed = true;
			end
		else
			session.multiplexed_from = nil; -- don't hold destroyed sessions.
		end
	end
	return s2s_make_authenticated(session, host);
end

local function can_do_dialback(origin)
	local db = origin.stream_declared_ns and origin.stream_declared_ns["db"];
	if db == xmlns_db then return true; else return false; end
end

local errors_map = {
	["item-not-found"] = "requested host was not found on the remote enitity",
	["remote-connection-failed"] = "the receiving entity failed to connect back to us",
	["remote-server-not-found"] = "received item-not-found or host-unknown while attempting to dialback",
	["remote-server-timeout"] = "time exceeded while attempting to contact the authoritative server",
	["policy-violation"] = "the receiving entity requires to enable TLS before executing dialback",
	["not-authorized"] = "the receiving entity denied dialback, probably  because it requires a valid certificate",
	["forbidden"] = "received a response of type invalid while authenticating with the authoritative server",
	["not-acceptable"] = "the receiving entity was unable to assert our identity"
};
local function handle_db_errors(origin, stanza)
	local attr = stanza.attr;
	local condition = stanza:child_with_name("error") and stanza:child_with_name("error")[1];
	local err = condition and errors_map[condition];
	local type = origin.type;
	local format;
	
	if err then
		format = ("Dialback non-fatal error: "..err.." (%s)"):format(type:find("s2sin.*") and attr.from or attr.to);
	else -- invalid error condition
		origin:close(
			{ condition = "not-acceptable", text = "Supplied error dialback condition is a non graceful one, good bye" },
			"stream failure"
		);
	end
	
	if format then 
		module:log("warn", format);
		if origin.bounce_sendq then origin:bounce_sendq(err); end
	end
	return true;
end
local function send_db_error(origin, name, condition, from, to, id, mp)
	local db_error = st.stanza(name, { from = from, to = to, id = id })
		:tag("error", { type = "cancel" })
			:tag(condition, { xmlns = xmlns_stanzas });
	
	if origin then
		origin:send(db_error);
	else
		module:fire_event("route/remote", {
			from_host = from, to_host = to, multiplexed_from = mp, stanza = db_error;
		});
	end
	return true;
end

module:hook("stanza/"..xmlns_db..":verify", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sin_unauthed" or origin.type == "s2sin" then
		origin.log("debug", "verifying that dialback key is ours...");
		local attr = stanza.attr;
		if attr.type then
			module:log("warn", "Ignoring incoming session from %s claiming a dialback key for %s is %s",
				origin.from_host or "(unknown)", attr.from or "(unknown)", attr.type);
			return true;
		end

		local type;
		if verify_dialback(attr.id, attr.from, attr.to, stanza[1]) then
			type = "valid";
			if origin.type == "s2sin" then
				local s2sout = hosts[attr.to].s2sout[attr.from];
				if s2sout and origin.from_host ~= attr.from then s2sout.multiplexed_from = origin; end
			end
		else
			type = "invalid";
			origin.log("warn", "Asked to verify a dialback key that was incorrect. An imposter is claiming to be %s?", attr.to);
		end
		origin.log("debug", "verified dialback key... it is %s", type);
		origin.sends2s(st.stanza("db:verify", { from = attr.to, to = attr.from, id = attr.id, type = type }):text(stanza[1]));
		return true;
	end
end);

module:hook("stanza/"..xmlns_db..":result", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sin_unauthed" or origin.type == "s2sin" then
		local attr = stanza.attr;
		local to, from = nameprep(attr.to), nameprep(attr.from);
		local is_multiplexed_from;

		if not origin.from_host then
			origin.from_host = from;
		end
		if not origin.to_host then
			origin.to_host = to;
		end
		if origin.from_host ~= from then -- multiplexed stream
			is_multiplexed_from = origin;
		end
		
		if not hosts[to] then
			if is_multiplexed_from then
				-- Assume the remote entity supports graceful dialback errors
				return send_db_error(nil, "db:result", "item-not-found", to, from, origin.streamid, is_multiplexed_from);
			else
				origin.log("info", "%s tried to connect to %s, which we don't serve", from, to);
				origin:close("host-unknown");
				return true;
			end
		elseif not from then
			origin:close("improper-addressing");
			return true;
		end
		
		origin.hosts[from] = { dialback_key = stanza[1] };
		dialback_requests[from.."/"..origin.streamid] = origin;
		
		origin.log("debug", "asking %s if key %s belongs to them", from, stanza[1]);
		module:fire_event("route/remote", {
			from_host = to, to_host = from, multiplexed_from = is_multiplexed_from,
			stanza = st.stanza("db:verify", { from = to, to = from, id = origin.streamid }):text(stanza[1])
		});
		return true;
	end
end);

module:hook("stanza/"..xmlns_db..":verify", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sout_unauthed" or origin.type == "s2sout" then
		local attr = stanza.attr;
		local dialback_verifying = dialback_requests[attr.from.."/"..(attr.id or "")];
		if dialback_verifying and attr.from == origin.to_host then
			local valid, authed;
			if attr.type == "valid" then
				authed = make_authenticated(dialback_verifying, attr.from);
				valid = "valid";
			elseif attr.type == "error" then
				dialback_requests[attr.from.."/"..(attr.id or "")] = nil;
				return handle_db_errors(origin, stanza);
			else
				log("warn", "authoritative server for %s denied the key", attr.from or "(unknown)");
				valid = "invalid";
			end
			if authed and dialback_verifying.destroyed then
				log("warn", "Incoming s2s session %s was closed in the meantime, so we can't notify it of the db result", tostring(dialback_verifying):match("%w+$"));
			elseif authed then
				dialback_verifying.sends2s(
					st.stanza("db:result", { from = attr.to, to = attr.from, id = attr.id, type = valid }):text(dialback_verifying.hosts[attr.from].dialback_key)
				);
			end
			dialback_requests[attr.from.."/"..(attr.id or "")] = nil;
			if not authed then origin:close("not-authorized", "authentication failure"); end -- we close the outgoing stream
		end
		return true;
	end
end);

module:hook("stanza/"..xmlns_db..":result", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sout_unauthed" or origin.type == "s2sout" then
		local attr = stanza.attr;
		if not hosts[attr.to] then
			origin:close("host-unknown");
			return true;
		elseif hosts[attr.to].s2sout[attr.from] ~= origin then
			-- This isn't right
			origin:close("invalid-id");
			return true;
		end
		if attr.type == "valid" then
			make_authenticated(origin, attr.from);
		elseif attr.type == "error" then
			return handle_db_errors(origin, stanza);
		else
			origin:close("not-authorized", "authentication failure");
		end
		return true;
	end
end);

module:hook_stanza("urn:ietf:params:xml:ns:xmpp-sasl", "failure", function (origin, stanza)
	if origin.external_auth == "failed" and can_do_dialback(origin) then
		module:log("debug", "SASL EXTERNAL failed, falling back to dialback");
		origin.can_do_dialback = true;
		initiate_dialback(origin);
		return true;
	else
		module:log("debug", "SASL EXTERNAL failed and no dialback available, closing stream(s)");
		origin:close();
		return true;
	end
end, 100);

module:hook_stanza(xmlns_stream, "features", function (origin, stanza)
	if not origin.external_auth or origin.external_auth == "failed" then
		local tls = stanza:child_with_ns(xmlns_starttls);
		if can_do_dialback(origin) then
			local tls_required = tls and tls:get_child("required");
			if tls_required and not origin.secure then
				local to, from = origin.to_host, origin.from_host;
				module:log("warn", "Remote server mandates to encrypt streams but TLS is not available for this host,");
				module:log("warn", "please check your configuration and that mod_tls is loaded correctly");
				-- Close paired incoming stream
				for session in pairs(incoming) do
					if session.from_host == to and session.to_host == from and not session.multiplexed_stream then
						session:close("internal-server-error", "dialback authentication failed on paired outgoing stream");
					end
				end
				return;
			end
			
			module:log("debug", "Initiating dialback...");
			origin.can_do_dialback = true;
			initiate_dialback(origin);
		end
	end
end, 100);

module:hook("s2s-stream-features", function (data)
	data.features:tag("dialback", { xmlns = "urn:xmpp:features:dialback" }):tag("errors"):up():up();
end, 98);

module:hook("s2s-authenticate-legacy", function (event)
	event.origin.legacy_dialback = true;
	module:log("debug", "Initiating dialback...");
	initiate_dialback(event.origin);
	return true;
end, 100);

function module.load()
	host_session.dialback_capable = true;
end

function module.unload(reload)
	if not reload and not s2s_strict_mode then
		module:log("warn", "In interoperability mode mod_s2s directly depends on mod_dialback for its local instances.");
		module:log("warn", "Perhaps it will be unloaded as well for this host. (To prevent this set s2s_strict_mode = true in the config)");
	end
	host_session.dialback_capable = nil;
end

module:hook_global("config-reloaded", function()
	s2s_strict_mode = module:get_option_boolean("s2s_strict_mode", false);
	require_encryption = module:get_option_boolean("s2s_require_encryption", false);
end);
