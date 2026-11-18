-- Namecheap reports most failures inside an HTTP 200 XML envelope; each maps to a clear, classified error.
local function envelope(status: string, inner: string): string
	return '<?xml version="1.0" encoding="utf-8"?><ApiResponse Status="' .. status .. '" xmlns="http://api.namecheap.com/xml.response">' .. inner .. '</ApiResponse>'
end

return {
	scenario = {publisher = {}, auth_method = "token", auth_config = {token = "fixture-key"},
		config = {api_host = "api.namecheap.com", username = "ada", client_ip = "203.0.113.7"}},
	access = {data = "read"},
	configure = function()
		calls = 0
		status = 200
		payload = ""
		http = {request = function(req)
			calls += 1
			return fixture.operation({statusCode = status, headers = {}, body = fixture.reader(payload)})
		end}
	end,
	run = function(namecheap)
		local function upstream(code, body, expected)
			status, payload = code, body
			local before = calls
			local ok, err = pcall(function() namecheap.getDnsRecords("example.com") end)
			for _, text in expected do
				assert(not ok and string.find(tostring(err), text, 1, true), "missing " .. text .. " in " .. tostring(err))
			end
			assert(calls == before + 1, "a failed call was retried")
		end
		upstream(200, envelope("ERROR", '<Errors><Error Number="1011150">Invalid request IP: 198.51.100.4</Error></Errors><CommandResponse />'),
			{"error 1011150", "Invalid request IP", "203.0.113.7 is whitelisted", '"retryable":false', '"layer":"upstream"'})
		upstream(200, envelope("ERROR", '<Errors><Error Number="1011102">API Key is invalid or API access has not been enabled</Error></Errors>'),
			{"error 1011102", "API access has not been enabled", '"retryable":false'})
		upstream(200, envelope("ERROR", '<Errors><Error Number="2019166">Domain not found</Error><Error Number="5050900">Unhandled exceptions</Error></Errors>'),
			{"error 2019166: Domain not found; error 5050900", '"retryable":true'})
		upstream(405, "Too many requests", {"HTTP 405", "rate limit", '"retryable":true'})
		upstream(503, "<html>Service Unavailable</html>", {"HTTP 503", '"retryable":true'})
		upstream(200, "<html><body>Maintenance</body>", {"not its XML API format"})
		upstream(200, '{"status":"ok"}', {"not its XML API format"})
		upstream(200, envelope("ERROR", "<Errors />"), {"status ERROR without an error"})
		upstream(200, envelope("OK", "<Errors />"), {"no CommandResponse"})
		upstream(200, envelope("OK", '<Errors /><CommandResponse Type="x" />'), {"no DomainDNSGetHostsResult"})
	end,
}
