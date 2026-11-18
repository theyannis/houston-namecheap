-- changeDnsRecords reads the zone, writes the complete record set by POST, reads it back, and guards mail settings.
local function decode(value: string): string
	value = string.gsub(value, "+", " ")
	return (string.gsub(value, "%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local function form(body: string): ({{string}}, {[string]: string})
	local pairs, map = {}, {}
	for part in string.gmatch(body, "[^&]+") do
		local key, value = string.match(part, "^([^=]*)=(.*)$")
		table.insert(pairs, {decode(key), decode(value)})
		map[decode(key)] = decode(value)
	end
	return pairs, map
end

local function attr(value: string): string
	return (string.gsub(string.gsub(string.gsub(value, "&", "&amp;"), '"', "&quot;"), "<", "&lt;"))
end

local function hostsXML(): string
	local rows = {}
	for index, host in zone.hosts do
		table.insert(rows, string.format('<host HostId="%d" Name="%s" Type="%s" Address="%s" MXPref="%d" TTL="%d" IsActive="true" />',
			index, attr(host.Name), host.Type, attr(host.Address), host.MXPref or 10, host.TTL or 1799))
	end
	return '<?xml version="1.0" encoding="utf-8"?><ApiResponse Status="OK"><Errors /><CommandResponse Type="namecheap.domains.dns.getHosts">'
		.. string.format('<DomainDNSGetHostsResult Domain="example.com" EmailType="%s" IsUsingOurDNS="%s">', zone.emailType, tostring(zone.ourDNS))
		.. table.concat(rows) .. '</DomainDNSGetHostsResult></CommandResponse></ApiResponse>'
end

local BASE = "https://api.namecheap.com/xml.response?ApiUser=ada&UserName=ada&ClientIp=203.0.113.7"

return {
	scenario = {publisher = {}, auth_method = "token", auth_config = {token = "fixture-key"},
		config = {api_host = "api.namecheap.com", username = "ada", client_ip = "203.0.113.7"}},
	access = {data = "write"},
	configure = function()
		requests = {}
		zone = {}
		http = {request = function(req)
			table.insert(requests, req)
			if req.method == "GET" then
				assert(string.find(req.url, "&Command=namecheap.domains.dns.getHosts&SLD=example&TLD=com", 1, true), req.url)
				return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(hostsXML())})
			end
			assert(req.method == "POST" and req.url == BASE .. "&Command=namecheap.domains.dns.setHosts", req.url)
			assert(req.headers["Content-Type"][1] == "application/x-www-form-urlencoded")
			local _, fields = form(req.body)
			if zone.reject then
				return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader('<ApiResponse Status="OK"><Errors /><CommandResponse>'
					.. '<DomainDNSSetHostsResult Domain="example.com" IsSuccess="false" /></CommandResponse></ApiResponse>')})
			end
			local written = {}
			local index = 1
			while fields["HostName" .. index] do
				table.insert(written, {Name = fields["HostName" .. index], Type = fields["RecordType" .. index], Address = fields["Address" .. index],
					MXPref = tonumber(fields["MXPref" .. index]), TTL = tonumber(fields["TTL" .. index])})
				index += 1
			end
			zone.hosts = written
			if fields.EmailType then zone.emailType = fields.EmailType end
			if zone.tamper then table.insert(zone.hosts, {Name = "rogue", Type = "A", Address = "198.51.100.9"}) end
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader('<ApiResponse Status="OK"><Errors /><CommandResponse>'
				.. '<DomainDNSSetHostsResult Domain="example.com" IsSuccess="true" /></CommandResponse></ApiResponse>')})
		end}
	end,
	run = function(namecheap)
		assert(type(namecheap.changeDnsRecords) == "function" and type(namecheap.getDnsRecords) == "function")
		local function setZone(emailType, hosts, extra)
			zone = {emailType = emailType, ourDNS = true, hosts = hosts}
			for k, v in extra or {} do zone[k] = v end
			requests = {}
		end
		local function webZone()
			return {
				{Name = "@", Type = "A", Address = "192.0.2.10"},
				{Name = "@", Type = "TXT", Address = "v=spf1 -all", TTL = 300},
				{Name = "www", Type = "CNAME", Address = "old.example.net.", TTL = 300},
			}
		end
		local function rejects(fn, text, expectedRequests)
			local ok, err = pcall(fn)
			assert(not ok and string.find(tostring(err), text, 1, true), "expected " .. text .. ", got " .. tostring(err))
			assert(#requests == expectedRequests, "expected " .. expectedRequests .. " requests, got " .. #requests)
			for _, req in requests do assert(req.method == "GET", "a refused change must not write") end
		end

		-- Replace a record and add another: every other record is written back unchanged.
		setZone("NONE", webZone())
		local result = namecheap.changeDnsRecords("example.com", {
			remove = {{Name = "WWW", Type = "cname"}},
			add = {
				{Name = "www", Type = "CNAME", Address = "example.netlify.app", TTL = 300},
				{Name = "_acme-challenge", Type = "TXT", Address = "token &=+ x"},
			},
		})
		assert(#requests == 3 and requests[1].method == "GET" and requests[2].method == "POST" and requests[3].method == "GET")
		local sent = form(requests[2].body)
		local expected = {
			{"SLD", "example"}, {"TLD", "com"},
			{"HostName1", "@"}, {"RecordType1", "A"}, {"Address1", "192.0.2.10"}, {"TTL1", "1799"},
			{"HostName2", "@"}, {"RecordType2", "TXT"}, {"Address2", "v=spf1 -all"}, {"TTL2", "300"},
			{"HostName3", "www"}, {"RecordType3", "CNAME"}, {"Address3", "example.netlify.app"}, {"TTL3", "300"},
			{"HostName4", "_acme-challenge"}, {"RecordType4", "TXT"}, {"Address4", "token &=+ x"},
		}
		assert(#sent == #expected, "sent " .. #sent .. " fields: " .. requests[2].body)
		for i, pair in expected do
			assert(sent[i][1] == pair[1] and sent[i][2] == pair[2], "field " .. i .. ": " .. sent[i][1] .. "=" .. sent[i][2])
		end
		assert(string.find(requests[2].body, "Address4=token%20%26%3D%2B%20x", 1, true), requests[2].body)
		assert(not string.find(requests[2].body, "EmailType", 1, true), "a change without mail records keeps the mail setting")
		assert(not string.find(requests[2].body, "MXPref", 1, true), "MXPref is sent only for MX records")
		assert(result.Changed == true and result.Added == 2 and result.Removed == 1 and result.Updated == 0)
		assert(result.Verified == true and result.VerifyError == nil and result.EmailType == "NONE" and #result.Hosts == 4)

		-- Adding a record that already exists writes nothing.
		setZone("NONE", webZone())
		result = namecheap.changeDnsRecords("example.com", {add = {{Name = "www", Type = "CNAME", Address = "OLD.example.net"}}})
		assert(#requests == 1 and result.Changed == false and result.Unchanged == 1 and result.Added == 0)

		-- Adding an existing record with a new TTL updates it in place.
		setZone("NONE", webZone())
		result = namecheap.changeDnsRecords("example.com", {add = {{Name = "@", Type = "A", Address = "192.0.2.10", TTL = 600}}})
		local _, fields = form(requests[2].body)
		assert(result.Updated == 1 and result.Added == 0 and fields.TTL1 == "600" and fields.HostName4 == nil)

		-- A remove rule that matches nothing stops the change before any write.
		setZone("NONE", webZone())
		rejects(function() namecheap.changeDnsRecords("example.com", {remove = {{Name = "api"}}}) end, "remove[1] matched no record", 1)

		-- Adding MX records to a NONE zone switches it to MX mail and sends MXPref.
		setZone("NONE", webZone())
		result = namecheap.changeDnsRecords("example.com", {add = {{Name = "@", Type = "MX", Address = "mx.example.net", MXPref = 10}}})
		_, fields = form(requests[2].body)
		assert(fields.EmailType == "MX" and fields.RecordType4 == "MX" and fields.MXPref4 == "10" and result.EmailType == "MX" and result.Verified)

		-- A Gmail preset is never switched silently, but can be switched on request.
		setZone("GMAIL", webZone())
		rejects(function()
			namecheap.changeDnsRecords("example.com", {add = {{Name = "@", Type = "MX", Address = "mx.example.net", MXPref = 10}}})
		end, 'Pass EmailType = "MX"', 1)
		setZone("GMAIL", webZone())
		result = namecheap.changeDnsRecords("example.com", {EmailType = "MX", add = {{Name = "@", Type = "MX", Address = "mx.example.net", MXPref = 10}}})
		_, fields = form(requests[2].body)
		assert(fields.EmailType == "MX" and result.EmailType == "MX")

		-- A preset zone keeps its preset on an unrelated change.
		setZone("FWD", webZone())
		namecheap.changeDnsRecords("example.com", {add = {{Name = "blog", Type = "A", Address = "192.0.2.20"}}})
		assert(not string.find(requests[2].body, "EmailType", 1, true))

		-- On an MX zone, existing MX records are kept by sending the current mode.
		local mailZone = webZone()
		table.insert(mailZone, {Name = "@", Type = "MX", Address = "mx1.example.net", MXPref = 5})
		setZone("MX", mailZone)
		namecheap.changeDnsRecords("example.com", {add = {{Name = "_dmarc", Type = "TXT", Address = "v=DMARC1; p=none"}}})
		_, fields = form(requests[2].body)
		assert(fields.EmailType == "MX" and fields.RecordType4 == "MX" and fields.MXPref4 == "5")

		-- An EmailType that would drop remaining MX records is refused.
		setZone("MX", mailZone)
		rejects(function()
			namecheap.changeDnsRecords("example.com", {EmailType = "NONE", add = {{Name = "x", Type = "A", Address = "192.0.2.30"}}})
		end, "needs EmailType MX", 1)

		-- Domains on other nameservers are refused.
		setZone("NONE", webZone(), {ourDNS = false})
		rejects(function()
			namecheap.changeDnsRecords("example.com", {add = {{Name = "x", Type = "A", Address = "192.0.2.30"}}})
		end, "uses custom nameservers", 1)

		-- Namecheap's IsSuccess="false" is an error, and nothing is re-read.
		setZone("NONE", webZone(), {reject = true})
		local ok, err = pcall(function() namecheap.changeDnsRecords("example.com", {add = {{Name = "x", Type = "A", Address = "192.0.2.30"}}}) end)
		assert(not ok and string.find(tostring(err), "did not apply the change", 1, true) and #requests == 2)

		-- A read-back that differs from what was written is reported, not hidden.
		setZone("NONE", webZone(), {tamper = true})
		result = namecheap.changeDnsRecords("example.com", {add = {{Name = "x", Type = "A", Address = "192.0.2.30"}}})
		assert(result.Changed == true and result.Verified == false and string.find(result.VerifyError, "differ", 1, true))
		assert(#result.Hosts == 5, "Hosts reflects the read-back records")

		-- Invalid changes never reach the network.
		local function invalid(change, text)
			setZone("NONE", webZone())
			rejects(function() namecheap.changeDnsRecords("example.com", change) end, text, 0)
		end
		invalid({}, "add or remove at least one record")
		invalid({add = {{Name = "@", Type = "SRV", Address = "x"}}}, "add[1].Type must be one of")
		invalid({add = {{Name = "@", Type = "MX", Address = "mx.example.net"}}}, "add[1].MXPref must be an integer")
		invalid({add = {{Name = "@", Type = "A", Address = "192.0.2.1", MXPref = 10}}}, "MXPref is only for MX records")
		invalid({add = {{Name = "go", Type = "URL301", Address = "example.org"}}}, "must start with a protocol")
		invalid({add = {{Name = "@", Type = "A", Address = "192.0.2.1", TTL = 30}}}, "TTL must be an integer from 60 to 60000")
		invalid({add = {{Name = "@", Type = "A", Adress = "192.0.2.1"}}}, "unknown field Adress")
		invalid({remove = {{}}}, "remove[1] must name at least one")
		invalid({EmailType = "PROTON", add = {{Name = "@", Type = "A", Address = "192.0.2.1"}}}, "EmailType must be")
		invalid({replace = {}}, "unknown field replace")
	end,
}
