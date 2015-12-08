local uri_patts = require "lpeg_patterns.uri"
local base64 = require "base64"
local client_connect = require "http.client".connect
local new_headers = require "http.headers".new
local http_util = require "http.util"
local monotime = require "cqueues".monotime
local ce = require "cqueues.errno"

local request_methods = {
	follow_redirects = true;
	max_redirects = 5; -- false = no redirects
	expect_100_timeout = 1;
}
local request_mt = {
	__index = request_methods;
}

local function new_from_uri_t(uri_t, headers)
	local scheme = assert(uri_t.scheme, "URI missing scheme")
	assert(scheme == "https" or scheme == "http", "scheme not http")
	local host = tostring(assert(uri_t.host, "URI must include a host"))
	local path = uri_t.path
	if path == nil or path == "" then
		path = "/"
	else
		path = http_util.encodeURI(path)
	end
	if uri_t.query then
		path = path .. "?" .. http_util.encodeURI(uri_t.query)
	end
	if headers == nil then
		headers = new_headers()
	end
	local self = setmetatable({
		host = host;
		port = uri_t.port or (scheme == "https" and 443 or 80);
		tls = (scheme == "https");
		headers = headers;
		body = nil;
	}, request_mt)
	headers:upsert(":authority", http_util.to_authority(host, self.port, scheme))
	headers:upsert(":method", "GET")
	headers:upsert(":path", path)
	headers:upsert(":scheme", scheme)
	if uri_t.userinfo then
		headers:upsert("authorization", "basic " .. base64.encode(uri_t.userinfo), true)
	end
	if not headers:has("user-agent") then
		headers:append("user-agent", "lua-http")
	end
	return self
end

local function new_from_uri(uri)
	local uri_t = assert(uri_patts.uri:match(uri), "invalid URI")
	return new_from_uri_t(uri_t)
end

-- CONNECT requests are a bit special, see http2 spec section 8.3
local function new_connect(uri, connect_authority)
	local uri_t = assert(uri_patts.uri:match(uri), "invalid URI")
	assert(uri_t.path == "", "connect requests cannot have paths")
	local scheme = uri_t.scheme or "http" -- default to http
	assert(scheme == "https" or scheme == "http", "scheme not http")
	local host = tostring(assert(uri_t.host, "URI must include a host"))
	local self = setmetatable({
		host = host;
		port = uri_t.port or (scheme == "https" and 443 or 80);
		tls = (scheme == "https");
		headers = new_headers();
		body = nil;
	}, request_mt)
	self.headers:append(":authority", connect_authority)
	self.headers:append(":method", "CONNECT")
	if uri_t.userinfo then
		self.headers:append("proxy-authorization", "basic " .. base64.encode(uri_t.userinfo), true)
	end
	return self
end

local function new_from_stream(stream)
	local host, port
	local ssl = stream:checktls()
	local request_headers = stream:get_headers()
	local scheme = request_headers:get(":scheme") or (ssl and "https" or "http")
	if request_headers:has(":authority") then
		host, port = http_util.split_authority(request_headers:get(":authority"), scheme)
	else
		local fam -- luacheck: ignore 231
		fam, host, port = stream:localname()
		host = ssl:getHostName() or host
	end

	local self = setmetatable({
		host = host;
		port = port;
		tls = ssl ~= nil; -- TODO: create ssl context?
		headers = request_headers;
		body = stream:read_body_to_tmpfile(request_headers); -- TODO: doesn't make sense for CONNECT
	}, request_mt)

	return self
end

function request_methods:to_url()
	local scheme = self.headers:get(":scheme")
	local authority = self.headers:get(":authority")
	if authority == nil then
		authority = http_util.to_authority(self.host, self.port, scheme)
	end
	-- TODO: userinfo section (username/password)
	local path = self.headers:get(":path")
	return scheme .. "://" .. authority .. path
end

function request_methods:to_curl()
	local cmd = {
		"curl";
		"--location-trusted";
		"--post301";
		"--post302";
		"--post303";
	}
	local n = 5

	if self.max_redirects ~= 50 then
		cmd[n+1] = "--max-redirs"
		cmd[n+2] = string.format("%d", self.max_redirects or -1)
		n = n + 2
	end

	if self.expect_100_timeout ~= 1 then
		error("NYI") -- the option to change this curl setting isn't in man page
	end

	if self.tls and self.tls ~= true then
		error("NYI")
	end

	local scheme = self.headers:get(":scheme")
	-- Unlike the ':tourl' method, curl needs the authority in the URI to be the actual host/port
	local authority = http_util.to_authority(self.host, self.port, scheme)
	local path = self.headers:get(":path")
	cmd[n+1] = scheme .. "://" .. authority .. path
	n = n + 1

	for name, value in self.headers:each() do
		if name:sub(1,1) == ":" then
			if name == ":authority" then
				if value ~= authority then
					cmd[n+1] = "-H"
					cmd[n+2] = "host: " .. value
					n = n + 2
				end
			elseif name == ":method" then
				if value == "HEAD" then
					cmd[n+1] = "-I"
					n = n + 1
				elseif (value ~= "GET" or self.body ~= nil) and (value ~= "POST" or self.body == nil) then
					cmd[n+1] = "-X"
					cmd[n+2] = value
					n = n + 2
				end
			end
		elseif name == "user-agent" then
			cmd[n+1] = "-A"
			cmd[n+2] = value
			n = n + 2
		else
			cmd[n+1] = "-H"
			cmd[n+2] = name .. ": " .. value
			n = n + 2
		end
	end

	if self.body then
		if type(self.body) == "string" then
			cmd[n+1] = "--data-raw"
			cmd[n+2] = self.body
			n = n + 2
		else
			error("NYI")
		end
	end

	-- escape ready for a command line
	for i=1, n do
		local arg = cmd[i]
		if arg:match("[^%w%_%:%/%@%^%.%-]") then
			cmd[i] = "'" .. arg:gsub("'", "'\\''") .. "'"
		end
	end
	return table.concat(cmd, " ", 1, n)
end

function request_methods:new_stream(timeout)
	-- TODO: pooling
	local connection = client_connect({
		host = self.host;
		port = self.port;
		tls = self.tls;
	}, timeout)
	return connection:new_stream()
end

function request_methods:handle_redirect(orig_headers)
	local max_redirects = self.max_redirects
	if max_redirects == false or max_redirects <= 0 then
		return nil, "maximum redirects exceeded", ce.ELOOP
	end
	local location = assert(orig_headers:get("location"), "missing location header for redirect")
	local uri_t = assert(uri_patts.uri_reference:match(location), "invalid URI")
	local orig_scheme = self.headers:get(":scheme")
	if uri_t.scheme == nil then
		uri_t.scheme = orig_scheme
	end
	if uri_t.host == nil then
		uri_t.host, uri_t.port = http_util.split_authority(self.headers:get(":authority"), orig_scheme)
	end
	if uri_t.path ~= nil then
		uri_t.path = http_util.encodeURI(uri_t.path)
		if uri_t.path:sub(1, 1) ~= "/" then -- relative path
			local orig_target = self.headers:get(":path")
			local orig_path = assert(uri_patts.uri_reference:match(orig_target)).path
			orig_path = http_util.encodeURI(orig_path)
			uri_t.path = http_util.resolve_relative_path(orig_path, uri_t.path)
		end
	end
	local new_req = new_from_uri_t(uri_t)
	new_req.follow_redirects = rawget(self, "follow_redirects")
	if type(max_redirects) == "number" then
		new_req.max_redirects = max_redirects - 1
	end
	new_req.expect_100_timeout = rawget(self, "expect_100_timeout")
	new_req.body = self.body
	return new_req
end

function request_methods:set_body(body)
	self.body = body
	local length
	if type(self.body) == "string" then
		length = #body
	end
	if length then
		self.headers:upsert("content-length", string.format("%d", #body))
	end
	if not length or length > 1024 then
		self.headers:append("expect", "100-continue")
	end
end

function request_methods:go(timeout)
	local deadline = timeout and (monotime()+timeout)

	local stream do
		local err, errno
		stream, err, errno = self:new_stream(timeout)
		if stream == nil then return nil, err, errno end
	end

	do -- Write outgoing headers
		local ok, err, errno = stream:write_headers(self.headers, not self.body, deadline and (deadline-monotime()))
		if not ok then return nil, err, errno end
	end

	local headers
	if self.body then
		if self.headers:get("expect") == "100-continue" then
			-- Try to wait for 100-continue before proceeding
			if deadline then
				local err, errno
				headers, err, errno = stream:get_headers(math.min(self.expect_100_timeout, deadline-monotime()))
				if headers == nil and (err ~= ce.TIMEOUT or monotime() > deadline) then return nil, err, errno end
			else
				local err, errno
				headers, err, errno = stream:get_headers(self.expect_100_timeout)
				if headers == nil and err ~= ce.TIMEOUT then return nil, err, errno end
			end
		end
		if type(self.body) == "string" then
			local ok, err, errno = stream:write_body_from_string(self.body, deadline and (deadline-monotime()))
			if not ok then return nil, err, errno end
		elseif io.type(self.body) == "file" then
			local ok, err, errno = stream:write_body_from_file(self.body, deadline and (deadline-monotime()))
			if not ok then return nil, err, errno end
		elseif type(self.body) == "function" then
			-- call function to get body segments
			while true do
				local chunk = self.body(deadline and (deadline-monotime()))
				if chunk then
					local ok, err2, errno2 = stream:write_chunk(chunk, false, deadline and (deadline-monotime()))
					if not ok then return nil, err2, errno2 end
				else
					local ok, err2, errno2 = stream:write_chunk("", true, deadline and (deadline-monotime()))
					if not ok then return nil, err2, errno2 end
					break
				end
			end
		end
	end
	if not headers or headers:get(":status") == "100" then
		repeat -- Skip through 100-continue headers
			local err, errno
			headers, err, errno = stream:get_headers(deadline and (deadline-monotime()))
			if headers == nil then return nil, err, errno end
		until headers:get(":status") ~= "100"
	end

	if self.follow_redirects and headers:get(":status"):sub(1,1) == "3" then
		stream:shutdown()
		local new_req, err2, errno2 = self:handle_redirect(headers)
		if not new_req then return nil, err2, errno2 end
		return new_req:go(deadline and (deadline-monotime()))
	end

	return headers, stream
end

return {
	new_from_uri = new_from_uri;
	new_connect = new_connect;
	new_from_stream = new_from_stream;
	methods = request_methods;
	mt = request_mt;
}
