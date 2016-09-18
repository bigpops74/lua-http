-- Methods common to both http 1 and http 2 streams

local cqueues = require "cqueues"
local monotime = cqueues.monotime
local ce = require "cqueues.errno"
local new_headers = require "http.headers".new

local CHUNK_SIZE = 2^20 -- write in 1MB chunks

local stream_methods = {}

function stream_methods:checktls()
	return self.connection:checktls()
end

function stream_methods:localname()
	return self.connection:localname()
end

function stream_methods:peername()
	return self.connection:peername()
end

-- 100-Continue response
local continue_headers = new_headers()
continue_headers:append(":status", "100")
function stream_methods:write_continue(timeout)
	return self:write_headers(continue_headers, false, timeout)
end

-- need helper to discard 'last' argument
-- (which would otherwise end up going in 'timeout')
local function each_chunk_helper(self)
	return self:get_next_chunk()
end
function stream_methods:each_chunk()
	return each_chunk_helper, self
end

function stream_methods:get_body_as_string(timeout)
	local deadline = timeout and (monotime()+timeout)
	local body, i = {}, 0
	while true do
		local chunk, err, errno = self:get_next_chunk(timeout)
		if chunk == nil then
			if err == ce.EPIPE then
				break
			else
				return nil, err, errno
			end
		end
		i = i + 1
		body[i] = chunk
		timeout = deadline and (deadline-monotime())
	end
	return table.concat(body, "", 1, i)
end

function stream_methods:get_body_chars(n, timeout)
	local deadline = timeout and (monotime()+timeout)
	local body, i, len = {}, 0, 0
	while len < n do
		local chunk, err, errno = self:get_next_chunk(timeout)
		if chunk == nil then
			if err == ce.EPIPE then
				break
			else
				return nil, err, errno
			end
		end
		i = i + 1
		body[i] = chunk
		len = len + #chunk
		timeout = deadline and (deadline-monotime())
	end
	if i == 0 then
		return nil, ce.EPIPE
	end
	local r = table.concat(body, "", 1, i)
	if n < len then
		self:unget(r:sub(n+1, -1))
		r = r:sub(1, n)
	end
	return r
end

function stream_methods:get_body_until(pattern, plain, include_pattern, timeout)
	local deadline = timeout and (monotime()+timeout)
	local body
	while true do
		local chunk, err, errno = self:get_next_chunk(timeout)
		if chunk == nil then
			if err == ce.EPIPE then
				return body, err
			else
				return nil, err, errno
			end
		end
		if body then
			body = body .. chunk
		else
			body = chunk
		end
		local s, e = body:find(pattern, 1, plain)
		if s then
			if e < #body then
				self:unget(body:sub(e+1, -1))
			end
			if include_pattern then
				return body:sub(1, e)
			else
				return body:sub(1, s-1)
			end
		end
		timeout = deadline and (deadline-monotime())
	end
end

function stream_methods:save_body_to_file(file, timeout)
	local deadline = timeout and (monotime()+timeout)
	while true do
		local chunk, err, errno = self:get_next_chunk(timeout)
		if chunk == nil then
			if err == ce.EPIPE then
				break
			else
				return nil, err, errno
			end
		end
		assert(file:write(chunk))
		timeout = deadline and (deadline-monotime())
	end
	return true
end

function stream_methods:get_body_as_file(timeout)
	local file = assert(io.tmpfile())
	local ok, err, errno = self:save_body_to_file(file, timeout)
	if not ok then
		return nil, err, errno
	end
	assert(file:seek("set"))
	return file
end

function stream_methods:write_body_from_string(str, timeout)
	return self:write_chunk(str, true, timeout)
end

function stream_methods:write_body_from_file(file, timeout)
	local deadline = timeout and (monotime()+timeout)
	-- Can't use :lines here as in Lua 5.1 it doesn't take a parameter
	while true do
		local chunk, err = file:read(CHUNK_SIZE)
		if chunk == nil then
			if err then
				error(err)
			end
			break
		end
		local ok, err2, errno2 = self:write_chunk(chunk, false, deadline and (deadline-monotime()))
		if not ok then
			return nil, err2, errno2
		end
	end
	return self:write_chunk("", true, deadline and (deadline-monotime()))
end

return {
	methods = stream_methods;
}
