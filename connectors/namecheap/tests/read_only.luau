-- Read connections export the reads alone, send GET requests with exact parameters, and never write.
local function xml(body: string): string
	return '<?xml version="1.0" encoding="utf-8"?>\r\n<ApiResponse Status="OK" xmlns="http://api.namecheap.com/xml.response">'
		.. '<Errors /><Warnings /><RequestedCommand>namecheap.domains.getList</RequestedCommand>'
		.. '<CommandResponse Type="namecheap.domains.getList">' .. body .. '</CommandResponse>'
		.. '<Server>PHX01</Server><GMTTimeDifference>--5:00</GMTTimeDifference><ExecutionTime>0.04</ExecutionTime></ApiResponse>'
end

local PAGE = xml('<DomainGetListResult>'
	.. '<Domain ID="101" Name="example.com" User="ada" Created="03/01/2020" Expires="03/01/2027" IsExpired="false" IsLocked="true" AutoRenew="true" WhoisGuard="ENABLED" IsPremium="false" IsOurDNS="true"/>'
	.. '<Domain ID="102" Name="0001.io" User="ada" Created="05/02/2021" Expires="05/02/2026" IsExpired="true" IsLocked="false" AutoRenew="false" WhoisGuard="NOTPRESENT" IsPremium="false" IsOurDNS="false" />'
	.. '</DomainGetListResult><Paging><TotalItems>42</TotalItems><CurrentPage>2</CurrentPage><PageSize>20</PageSize></Paging>')
local EMPTY = xml('<DomainGetListResult /><Paging><TotalItems>0</TotalItems><CurrentPage>1</CurrentPage><PageSize>20</PageSize></Paging>')

local BASE = "https://api.namecheap.com/xml.response?ApiUser=ada&UserName=ada&ClientIp=203.0.113.7"

return {
	scenario = {publisher = {}, auth_method = "token", auth_config = {token = "fixture-key"},
		config = {api_host = "api.namecheap.com", username = "ada", client_ip = "203.0.113.7"}},
	access = {data = "read"},
	configure = function()
		requests = {}
		nextBody = PAGE
		http = {request = function(req)
			table.insert(requests, req)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(nextBody)})
		end}
	end,
	run = function(namecheap)
		assert(namecheap.changeDnsRecords == nil, "Read access must not export changeDnsRecords")
		for _, name in {"listDomains", "getDomain", "checkAvailability", "getNameservers", "getDnsRecords"} do
			assert(type(namecheap[name]) == "function", "missing read " .. name)
		end

		local page = namecheap.listDomains({ListType = "EXPIRING", SearchTerm = "ex ample&co", Page = 2, PageSize = 20, SortBy = "EXPIREDATE"})
		local req = requests[1]
		assert(req.method == "GET" and req.body == nil and req.headers == nil)
		assert(req.url == BASE .. "&Command=namecheap.domains.getList&ListType=EXPIRING&Page=2&PageSize=20&SearchTerm=ex%20ample%26co&SortBy=EXPIREDATE", req.url)
		assert(not string.find(req.url, "ApiKey", 1, true), "the API key is injected by Houston, never by the connector")
		assert(page.TotalItems == 42 and page.CurrentPage == 2 and page.PageSize == 20)
		assert(#page.Domains == 2)
		local first, second = page.Domains[1], page.Domains[2]
		assert(first.ID == 101 and first.Name == "example.com" and first.IsLocked == true and first.AutoRenew == true)
		assert(first.Expires == "03/01/2027" and first.WhoisGuard == "ENABLED" and first.IsOurDNS == true)
		assert(second.Name == "0001.io" and second.IsExpired == true and second.IsOurDNS == false, "names stay text")

		nextBody = EMPTY
		local empty = namecheap.listDomains()
		assert(requests[2].url == BASE .. "&Command=namecheap.domains.getList")
		assert(#empty.Domains == 0 and json.encode(empty.Domains) == "[]" and empty.TotalItems == 0)

		local function rejects(fn, text)
			local before = #requests
			local ok, err = pcall(fn)
			assert(not ok and string.find(tostring(err), text, 1, true), "expected " .. text .. ", got " .. tostring(err))
			assert(#requests == before, "invalid input reached the network")
		end
		rejects(function() namecheap.listDomains({ListType = "SOON"}) end, "ListType must be")
		rejects(function() namecheap.listDomains({PageSize = 5}) end, "PageSize must be an integer from 10 to 100")
		rejects(function() namecheap.listDomains({Page = 1.5}) end, "Page must be an integer")
		rejects(function() namecheap.listDomains({Sort = "NAME"}) end, "unknown field Sort")
		rejects(function() namecheap.getDnsRecords("https://example.com/") end, "registered domain name")
		rejects(function() namecheap.getDnsRecords("") end, "domain must be a nonempty string")
		rejects(function() namecheap.checkAvailability({}) end, "1 to 50 domain names")
		local many = {}
		for i = 1, 51 do many[i] = "d" .. i .. ".com" end
		rejects(function() namecheap.checkAvailability(many) end, "1 to 50 domain names")

		for _, req2 in requests do
			assert(req2.method == "GET", "Read connections only send GET")
		end
	end,
}
