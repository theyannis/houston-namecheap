-- Namecheap XML API (https://www.namecheap.com/support/api/). Credentials stay on Houston.
-- Arguments and results keep Namecheap's native field names.
type Element = {name: string, attrs: {[string]: string}, children: {Element}, text: string}
type Plain = {[string]: any}

local PROVIDER = "Namecheap"
local MAX_BODY = 4 * 1024 * 1024
local DEFAULT_TTL = 1799
local SERVER_ERRORS = {["3050900"] = true, ["5019169"] = true, ["5050169"] = true, ["5050900"] = true}
local LIST_TYPES = {ALL = true, EXPIRING = true, EXPIRED = true}
local SORT_BY = {NAME = true, NAME_DESC = true, EXPIREDATE = true, EXPIREDATE_DESC = true, CREATEDATE = true, CREATEDATE_DESC = true}
local RECORD_TYPES = {A = true, AAAA = true, ALIAS = true, CAA = true, CNAME = true, MX = true, MXE = true, NS = true, TXT = true, URL = true, URL301 = true, FRAME = true}
local EMAIL_TYPES = {NONE = true, MXE = true, MX = true, FWD = true, OX = true, GMAIL = true}
-- Record types whose addresses are host names or IPs, compared without case.
local CASELESS = {A = true, AAAA = true, ALIAS = true, CNAME = true, MX = true, MXE = true, NS = true}

-- XML --------------------------------------------------------------------

local ENTITIES = {amp = "&", lt = "<", gt = ">", quot = '"', apos = "'"}

local function unescape(value: string): string
	if string.find(value, "&", 1, true) == nil then
		return value
	end
	local parts: {string} = {}
	local pos = 1
	while true do
		local first, last, reference = string.find(value, "&([#%w]+);", pos)
		if first == nil or last == nil or reference == nil then
			table.insert(parts, string.sub(value, pos))
			break
		end
		table.insert(parts, string.sub(value, pos, first - 1))
		local replacement: string? = ENTITIES[reference]
		local hex = string.match(reference, "^#[xX](%x+)$")
		local decimal = string.match(reference, "^#(%d+)$")
		local code = if hex then tonumber(hex, 16) elseif decimal then tonumber(decimal) else nil
		if code and code <= 0x10FFFF then
			replacement = utf8.char(code)
		end
		table.insert(parts, replacement or string.sub(value, first, last))
		pos = last + 1
	end
	return table.concat(parts)
end

local function localName(name: string): string
	return string.match(name, ":([^:]+)$") or name
end

-- Parses one XML document into elements. Comments, processing instructions and DOCTYPE are skipped.
local function parseXML(source: string): Element
	local root: Element? = nil
	local stack: {Element} = {}
	local pos = 1
	local size = #source
	while pos <= size do
		local open = string.find(source, "<", pos, true)
		local current = stack[#stack]
		local textEnd = if open then open - 1 else size
		if current and textEnd >= pos then
			current.text ..= unescape(string.sub(source, pos, textEnd))
		end
		if not open then
			break
		end
		if string.sub(source, open, open + 3) == "<!--" then
			local close = string.find(source, "-->", open + 4, true)
			assert(close, "unterminated comment")
			pos = close + 3
		elseif string.sub(source, open, open + 8) == "<![CDATA[" then
			local close = string.find(source, "]]>", open + 9, true)
			assert(close and current, "invalid CDATA section")
			current.text ..= string.sub(source, open + 9, close - 1)
			pos = close + 3
		elseif string.sub(source, open, open + 1) == "<?" then
			local close = string.find(source, "?>", open + 2, true)
			assert(close, "unterminated processing instruction")
			pos = close + 2
		elseif string.sub(source, open, open + 1) == "<!" then
			local close = string.find(source, ">", open + 2, true)
			assert(close, "unterminated declaration")
			pos = close + 1
		elseif string.sub(source, open, open + 1) == "</" then
			local close = string.find(source, ">", open + 2, true)
			assert(close, "unterminated end tag")
			local name = string.match(string.sub(source, open + 2, close - 1), "^%s*([^%s]+)%s*$")
			assert(current and name and localName(name) == current.name, "mismatched end tag")
			table.remove(stack)
			pos = close + 1
		else
			-- Find the tag's end outside quoted attribute values, which may contain ">".
			local cursor = open + 1
			local quote: string? = nil
			local close: number? = nil
			while cursor <= size do
				local found = string.find(source, if quote then quote else "[\"'>]", cursor, quote ~= nil)
				assert(found, "unterminated start tag")
				local char = string.sub(source, found, found)
				if quote then
					quote = nil
				elseif char == ">" then
					close = found
					break
				else
					quote = char
				end
				cursor = found + 1
			end
			assert(close, "unterminated start tag")
			local inner = string.sub(source, open + 1, close - 1)
			local selfClosing = string.sub(inner, -1) == "/"
			if selfClosing then
				inner = string.sub(inner, 1, -2)
			end
			local name, rest = string.match(inner, "^([%w_:%.%-]+)(.*)$")
			assert(name and rest, "invalid start tag")
			local element: Element = {name = localName(name), attrs = {}, children = {}, text = ""}
			local cursorAttr = 1
			while true do
				local first, last, key, _, value = string.find(rest, "^%s+([%w_:%.%-]+)%s*=%s*([\"'])(.-)%2", cursorAttr)
				if first == nil or last == nil or key == nil or value == nil then
					break
				end
				element.attrs[localName(key)] = unescape(value)
				cursorAttr = last + 1
			end
			assert(string.match(string.sub(rest, cursorAttr), "^%s*$"), "invalid attributes")
			if current then
				table.insert(current.children, element)
			elseif root == nil then
				root = element
			else
				error("more than one root element")
			end
			if not selfClosing then
				table.insert(stack, element)
			end
			pos = close + 1
		end
	end
	assert(root and #stack == 0, "incomplete document")
	return root
end

local function child(element: Element, name: string): Element?
	for _, node in element.children do
		if node.name == name then
			return node
		end
	end
	return nil
end

local function childrenNamed(element: Element, name: string): {Element}
	local found: {Element} = {}
	for _, node in element.children do
		if node.name == name then
			table.insert(found, node)
		end
	end
	return found
end

local function trim(value: string): string
	return (string.match(value, "^%s*(.-)%s*$")) :: string
end

-- Converts "true"/"false" to booleans and plain integers or decimals to numbers.
local function scalar(value: string): any
	local lower = string.lower(value)
	if lower == "true" then
		return true
	elseif lower == "false" then
		return false
	elseif string.match(value, "^%-?%d+$") and #value <= 15 and not string.match(value, "^%-?0%d") then
		return tonumber(value)
	elseif string.match(value, "^%-?%d+%.%d+$") and #value <= 17 then
		return tonumber(value)
	end
	return value
end

local function attrs(element: Element, raw: {[string]: boolean}?): Plain
	local out: Plain = {}
	for key, value in element.attrs do
		out[key] = if raw and raw[key] then value else scalar(value)
	end
	return out
end

-- A generic element tree: attributes and text-only children become fields; repeated or listed names become arrays.
local function plain(element: Element, arrays: {[string]: boolean}): Plain
	local out = attrs(element)
	local counts: {[string]: number} = {}
	for _, node in element.children do
		counts[node.name] = (counts[node.name] or 0) + 1
	end
	for _, node in element.children do
		local value: any
		if #node.children == 0 and next(node.attrs) == nil then
			value = scalar(trim(node.text))
		else
			value = plain(node, arrays)
			local text = trim(node.text)
			if text ~= "" then
				value.Value = scalar(text)
			end
		end
		if arrays[node.name] or counts[node.name] > 1 then
			if out[node.name] == nil then
				out[node.name] = json.decode("[]")
			end
			table.insert(out[node.name], value)
		else
			out[node.name] = value
		end
	end
	return out
end

-- Requests ---------------------------------------------------------------

local function fail(operation: string, message: string, status: number?, retryable: boolean?): never
	return houston.fail({
		operation = operation,
		layer = "upstream",
		upstream_status = status,
		retryable = retryable == true,
		message = message,
	})
end

local function invalid(message: string): never
	error(message, 0)
end

local function clientIp(): string
	local ip = config.client_ip
	local parts: {string} = {}
	if type(ip) == "string" then
		local a, b, c, d = string.match(ip, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
		if a and b and c and d then
			parts = {a, b, c, d}
		end
	end
	if #parts ~= 4 then
		invalid("The connection's Whitelisted IP address must be an IPv4 address such as 203.0.113.7")
	end
	for _, part in parts do
		local number = tonumber(part)
		if number == nil or number > 255 or (#part > 1 and string.sub(part, 1, 1) == "0") then
			invalid("The connection's Whitelisted IP address must be an IPv4 address such as 203.0.113.7")
		end
	end
	return ip
end

local function encodePairs(pairs: {{string}}): string
	local parts = {}
	for _, pair in pairs do
		table.insert(parts, url.encode(pair[1]) .. "=" .. url.encode(pair[2]))
	end
	return table.concat(parts, "&")
end

local function sortedPairs(params: {[string]: string}): {{string}}
	local keys = {}
	for key in params do
		table.insert(keys, key)
	end
	table.sort(keys)
	local out: {{string}} = {}
	for _, key in keys do
		table.insert(out, {key, params[key]})
	end
	return out
end

-- Calls one command. Reads send everything in the query; writes send their fields as a form body.
local function call(operation: string, command: string, params: {[string]: string}, form: {{string}}?): Element
	local username = config.username
	if type(username) ~= "string" or trim(username) == "" then
		invalid("The connection's Namecheap username is missing")
	end
	local ip = clientIp()
	local query = encodePairs({
		{"ApiUser", trim(username)}, {"UserName", trim(username)}, {"ClientIp", ip}, {"Command", command},
	})
	local extra = encodePairs(sortedPairs(params))
	if extra ~= "" then
		query ..= "&" .. extra
	end
	local target = "https://" .. config.api_host .. "/xml.response?" .. query
	local response = if form
		then await(http.request({
			method = "POST",
			url = target,
			headers = {["Content-Type"] = {"application/x-www-form-urlencoded"}},
			body = encodePairs(form),
		}))
		else await(http.request({method = "GET", url = target}))
	if response.statusCode ~= 200 then
		local snippet = await(response.body:readPrefix(512))
		local hint = if response.statusCode == 405 then " (Namecheap's rate limit; wait before retrying)" else ""
		return fail(operation, `{PROVIDER} answered HTTP {response.statusCode}{hint}: {snippet}`, response.statusCode,
			response.statusCode == 405 or response.statusCode == 429 or response.statusCode >= 500)
	end
	local raw = await(response.body:readAll(MAX_BODY))
	local ok, document = pcall(parseXML, raw)
	if not ok or document.name ~= "ApiResponse" then
		return fail(operation, `{PROVIDER} returned a response that is not its XML API format`, 200, false)
	end
	local errors = child(document, "Errors")
	local entries: {Element} = if errors then childrenNamed(errors, "Error") else {}
	if #entries > 0 then
		local messages = {}
		local retryable = false
		for _, entry in entries do
			local number = entry.attrs.Number or "?"
			retryable = retryable or SERVER_ERRORS[number] == true
			table.insert(messages, `error {number}: {trim(entry.text)}`)
		end
		local message = `{PROVIDER} {table.concat(messages, "; ")}`
		if string.find(string.lower(message), "%f[%a]ip%f[%A]") then
			message ..= `. Check that {ip} is whitelisted in Namecheap's API settings and is the address Houston connects from`
		end
		return fail(operation, message, 200, retryable)
	end
	if document.attrs.Status ~= "OK" then
		return fail(operation, `{PROVIDER} returned status {document.attrs.Status or "unknown"} without an error`, 200, false)
	end
	local result = child(document, "CommandResponse")
	if result == nil then
		return fail(operation, `{PROVIDER} returned no CommandResponse`, 200, false)
	end
	return result
end

local function requireResult(operation: string, response: Element, name: string): Element
	local result = child(response, name)
	if result == nil then
		return fail(operation, `{PROVIDER} returned no {name}`, 200, false)
	end
	return result
end

-- Arguments --------------------------------------------------------------

local function options(value: any, field: string, allowed: {[string]: boolean}): Plain
	if value == nil then
		return {}
	end
	if type(value) ~= "table" then
		invalid(field .. " must be a table")
	end
	for key in value do
		if type(key) ~= "string" or not allowed[key] then
			invalid(`{field} has an unknown field {tostring(key)}`)
		end
	end
	return value
end

local function text(value: any, field: string, maxLength: number): string
	if type(value) ~= "string" or trim(value) == "" then
		invalid(field .. " must be a nonempty string")
	end
	if #value > maxLength then
		invalid(`{field} must be at most {maxLength} characters`)
	end
	return trim(value)
end

local function integer(value: any, field: string, min: number, max: number): number
	if type(value) ~= "number" or value ~= math.floor(value) or value < min or value > max then
		invalid(`{field} must be an integer from {min} to {max}`)
	end
	return value
end

-- A registered domain such as example.com or example.co.uk, split at its first dot.
local function domainName(value: any): (string, string, string)
	local domain = string.lower(text(value, "domain", 253))
	if string.sub(domain, -1) == "." then
		domain = string.sub(domain, 1, -2)
	end
	if not string.match(domain, "^[%w%-]+%.[%w%-%.]+$") or string.find(domain, "..", 1, true)
		or string.sub(domain, -1) == "." then
		invalid("domain must be a registered domain name such as example.com, without http:// or a path")
	end
	local sld, tld = string.match(domain, "^([^%.]+)%.(.+)$")
	return domain, sld :: string, tld :: string
end

-- Reads ------------------------------------------------------------------

local function listDomains(opts: Plain?): Plain
	local input = options(opts, "options", {ListType = true, SearchTerm = true, Page = true, PageSize = true, SortBy = true})
	local params: {[string]: string} = {}
	if input.ListType ~= nil then
		if type(input.ListType) ~= "string" or not LIST_TYPES[input.ListType] then
			invalid("ListType must be ALL, EXPIRING or EXPIRED")
		end
		params.ListType = input.ListType
	end
	if input.SortBy ~= nil then
		if type(input.SortBy) ~= "string" or not SORT_BY[input.SortBy] then
			invalid("SortBy must be NAME, NAME_DESC, EXPIREDATE, EXPIREDATE_DESC, CREATEDATE or CREATEDATE_DESC")
		end
		params.SortBy = input.SortBy
	end
	if input.SearchTerm ~= nil then
		params.SearchTerm = text(input.SearchTerm, "SearchTerm", 70)
	end
	if input.Page ~= nil then
		params.Page = tostring(integer(input.Page, "Page", 1, 100000))
	end
	if input.PageSize ~= nil then
		params.PageSize = tostring(integer(input.PageSize, "PageSize", 10, 100))
	end
	local response = call("listDomains", "namecheap.domains.getList", params)
	local result = requireResult("listDomains", response, "DomainGetListResult")
	local domains = json.decode("[]")
	for _, node in childrenNamed(result, "Domain") do
		table.insert(domains, attrs(node, {Name = true, User = true}))
	end
	local paging = child(response, "Paging")
	local out: Plain = {Domains = domains}
	if paging then
		for _, field in {"TotalItems", "CurrentPage", "PageSize"} do
			local node = child(paging, field)
			if node then
				out[field] = tonumber(trim(node.text))
			end
		end
	end
	return out
end

local function getDomain(domain: string): Plain
	local name = domainName(domain)
	local response = call("getDomain", "namecheap.domains.getInfo", {DomainName = name})
	return plain(requireResult("getDomain", response, "DomainGetInfoResult"), {Nameserver = true, Rights = true})
end

local function checkAvailability(domains: {string}): Plain
	if type(domains) ~= "table" or #domains == 0 or #domains > 50 then
		invalid("domains must be an array of 1 to 50 domain names")
	end
	local names = {}
	for index, value in domains do
		if type(index) ~= "number" then
			invalid("domains must be an array of 1 to 50 domain names")
		end
		table.insert(names, (domainName(value)))
	end
	local response = call("checkAvailability", "namecheap.domains.check", {DomainList = table.concat(names, ",")})
	local results = json.decode("[]")
	for _, node in childrenNamed(response, "DomainCheckResult") do
		table.insert(results, attrs(node, {Domain = true}))
	end
	return {Results = results}
end

local function getNameservers(domain: string): Plain
	local _, sld, tld = domainName(domain)
	local response = call("getNameservers", "namecheap.domains.dns.getList", {SLD = sld, TLD = tld})
	local result = requireResult("getNameservers", response, "DomainDNSGetListResult")
	local out = attrs(result, {Domain = true})
	local servers = json.decode("[]")
	for _, node in childrenNamed(result, "Nameserver") do
		table.insert(servers, trim(node.text))
	end
	out.Nameservers = servers
	return out
end

local HOST_TEXT = {Name = true, Type = true, Address = true, AssociatedAppTitle = true, FriendlyName = true}

local function readHosts(operation: string, sld: string, tld: string): Plain
	local response = call(operation, "namecheap.domains.dns.getHosts", {SLD = sld, TLD = tld})
	local result = requireResult(operation, response, "DomainDNSGetHostsResult")
	local out = attrs(result, {Domain = true, EmailType = true})
	local hosts = json.decode("[]")
	for _, node in result.children do
		if string.lower(node.name) == "host" then
			table.insert(hosts, attrs(node, HOST_TEXT))
		end
	end
	out.Hosts = hosts
	return out
end

local function getDnsRecords(domain: string): Plain
	local _, sld, tld = domainName(domain)
	return readHosts("getDnsRecords", sld, tld)
end

-- DNS changes ------------------------------------------------------------

type Record = {Name: string, Type: string, Address: string, MXPref: number?, TTL: number?}

local function normName(name: string): string
	local value = string.lower(trim(name))
	return if value == "" then "@" else value
end

local function normAddress(recordType: string, address: string): string
	local value = trim(address)
	if CASELESS[recordType] then
		value = string.lower(value)
		if string.sub(value, -1) == "." and #value > 1 then
			value = string.sub(value, 1, -2)
		end
	end
	return value
end

-- Identity of a record: TTL is a property, not part of it.
local function identity(record: Record): string
	local pref = if record.Type == "MX" then tostring(record.MXPref or "") else ""
	return table.concat({normName(record.Name), record.Type, normAddress(record.Type, record.Address), pref}, "\0")
end

local function survives(recordType: string, emailType: string): boolean
	if recordType == "MX" then
		return emailType == "MX"
	elseif recordType == "MXE" then
		return emailType == "MXE" or emailType == "MX"
	end
	return true
end

local function isMail(recordType: string): boolean
	return recordType == "MX" or recordType == "MXE"
end

local function newRecord(value: any, index: number): Record
	local field = `add[{index}]`
	local input = options(value, field, {Name = true, Type = true, Address = true, MXPref = true, TTL = true})
	local recordType = string.upper(text(input.Type, field .. ".Type", 10))
	if not RECORD_TYPES[recordType] then
		invalid(`{field}.Type must be one of A, AAAA, ALIAS, CAA, CNAME, MX, MXE, NS, TXT, URL, URL301, FRAME`)
	end
	local record: Record = {
		Name = normName(text(input.Name, field .. ".Name", 255)),
		Type = recordType,
		Address = text(input.Address, field .. ".Address", 2048),
	}
	if input.TTL ~= nil then
		record.TTL = integer(input.TTL, field .. ".TTL", 60, 60000)
	end
	if recordType == "MX" then
		record.MXPref = integer(input.MXPref, field .. ".MXPref", 0, 65535)
	elseif input.MXPref ~= nil then
		invalid(`{field}.MXPref is only for MX records`)
	end
	if (recordType == "URL" or recordType == "URL301" or recordType == "FRAME")
		and not string.match(record.Address, "^%a[%w+.%-]*://") then
		invalid(`{field}.Address must start with a protocol such as https:// for {recordType} records`)
	end
	return record
end

type Selector = {Name: string?, Type: string?, Address: string?}

local function selector(value: any, index: number): Selector
	local field = `remove[{index}]`
	local input = options(value, field, {Name = true, Type = true, Address = true})
	local out: Selector = {}
	if input.Name ~= nil then
		out.Name = normName(text(input.Name, field .. ".Name", 255))
	end
	if input.Type ~= nil then
		out.Type = string.upper(text(input.Type, field .. ".Type", 10))
	end
	if input.Address ~= nil then
		out.Address = text(input.Address, field .. ".Address", 2048)
	end
	if out.Name == nil and out.Type == nil and out.Address == nil then
		invalid(`{field} must name at least one of Name, Type and Address`)
	end
	return out
end

local function matches(rule: Selector, record: Record): boolean
	if rule.Name and rule.Name ~= normName(record.Name) then
		return false
	end
	if rule.Type and rule.Type ~= record.Type then
		return false
	end
	if rule.Address and normAddress(record.Type, rule.Address) ~= normAddress(record.Type, record.Address) then
		return false
	end
	return true
end

local function list(value: any, field: string): {any}
	if value == nil then
		return {}
	end
	if type(value) ~= "table" then
		invalid(field .. " must be an array")
	end
	local count = 0
	for key in value do
		count += 1
		if type(key) ~= "number" then
			invalid(field .. " must be an array")
		end
	end
	if count ~= #value then
		invalid(field .. " must be an array without gaps")
	end
	return value
end

local function fromHost(host: Plain): Record
	local recordType = string.upper(tostring(host.Type or ""))
	local ttl = if type(host.TTL) == "number" then host.TTL else nil
	return {
		Name = tostring(host.Name or "@"),
		Type = recordType,
		Address = tostring(host.Address or ""),
		MXPref = if recordType == "MX" and type(host.MXPref) == "number" then host.MXPref else nil,
		TTL = ttl,
	}
end

local function recordList(records: {Record}): {Plain}
	local out = json.decode("[]")
	for _, record in records do
		table.insert(out, {Name = record.Name, Type = record.Type, Address = record.Address, MXPref = record.MXPref, TTL = record.TTL})
	end
	return out
end

local function stateKey(record: Record): string
	return identity(record) .. "\0" .. tostring(record.TTL or DEFAULT_TTL)
end

local function sameState(a: {Record}, b: {Record}): boolean
	local counts: {[string]: number} = {}
	for _, record in a do
		local key = stateKey(record)
		counts[key] = (counts[key] or 0) + 1
	end
	for _, record in b do
		local key = stateKey(record)
		if not counts[key] or counts[key] == 0 then
			return false
		end
		counts[key] -= 1
	end
	for _, count in counts do
		if count ~= 0 then
			return false
		end
	end
	return true
end

local function changeDnsRecords(domain: string, change: Plain): Plain
	local name, sld, tld = domainName(domain)
	local input = options(change, "change", {add = true, remove = true, EmailType = true})
	local adds: {Record} = {}
	for index, value in list(input.add, "add") do
		table.insert(adds, newRecord(value, index))
	end
	local removes: {Selector} = {}
	for index, value in list(input.remove, "remove") do
		table.insert(removes, selector(value, index))
	end
	if #adds == 0 and #removes == 0 then
		invalid("change must add or remove at least one record")
	end
	local requested: string? = nil
	if input.EmailType ~= nil then
		if type(input.EmailType) ~= "string" or not EMAIL_TYPES[input.EmailType] then
			invalid("EmailType must be NONE, MXE, MX, FWD, OX or GMAIL")
		end
		requested = input.EmailType
	end

	local zone = readHosts("changeDnsRecords", sld, tld)
	if zone.IsUsingOurDNS == false then
		invalid(`{name} uses custom nameservers, so Namecheap's DNS records for it are not served; change records at its DNS provider`)
	end
	local current = if type(zone.EmailType) == "string" and zone.EmailType ~= "" then string.upper(zone.EmailType) else "NONE"

	-- Remove: every selector must match at least one record, so a typo cannot pass silently.
	local kept: {Record} = {}
	local removed: {Record} = {}
	local used: {boolean} = {}
	for _, host in zone.Hosts do
		local record = fromHost(host)
		local hit = false
		for index, rule in removes do
			if matches(rule, record) then
				used[index] = true
				hit = true
			end
		end
		table.insert(if hit then removed else kept, record)
	end
	for index in removes do
		if not used[index] then
			invalid(`remove[{index}] matched no record in {name}; read the records with getDnsRecords first`)
		end
	end

	-- Add: an existing record with the same identity is updated in place (its TTL), not duplicated.
	local added, updated, unchanged = 0, 0, 0
	local addedMail = false
	for _, record in adds do
		local key = identity(record)
		local existing: Record? = nil
		for _, candidate in kept do
			if identity(candidate) == key then
				existing = candidate
				break
			end
		end
		if existing then
			if record.TTL ~= nil and (existing.TTL or DEFAULT_TTL) ~= record.TTL then
				existing.TTL = record.TTL
				updated += 1
			else
				unchanged += 1
			end
		else
			table.insert(kept, record)
			added += 1
			addedMail = addedMail or isMail(record.Type)
		end
	end
	local final = kept

	if added == 0 and updated == 0 and #removed == 0 then
		return {Domain = name, Changed = false, Added = 0, Updated = 0, Removed = 0, Unchanged = unchanged,
			EmailType = current, Verified = true, Hosts = recordList(final)}
	end

	-- Mail mode: MX rows survive only in MX mode, MXE rows in MXE or MX. A preset is never left silently.
	local hasMX, hasMXE = false, false
	for _, record in final do
		hasMX = hasMX or record.Type == "MX"
		hasMXE = hasMXE or record.Type == "MXE"
	end
	local send: string? = requested
	if send == nil then
		local derived: string? = nil
		if addedMail then
			derived = if hasMX then "MX" elseif hasMXE then "MXE" else nil
		end
		local recordDriven = current == "NONE" or current == "MX" or current == "MXE"
		if derived and derived ~= current and not recordDriven then
			invalid(`{name} uses Namecheap's {current} mail setting; these records need EmailType {derived}, which replaces it. Pass EmailType = "{derived}" to switch`)
		end
		send = derived or (if hasMX or hasMXE then current else nil)
	end
	for _, record in final do
		if isMail(record.Type) and not survives(record.Type, send or current) then
			local need = if record.Type == "MX" then "MX" else "MXE or MX"
			invalid(`{record.Type} record {record.Name} -> {record.Address} needs EmailType {need}, but the write would use {send or current}; Namecheap would drop it. Remove it or pass a matching EmailType`)
		end
	end

	local form: {{string}} = {{"SLD", sld}, {"TLD", tld}}
	if send then
		table.insert(form, {"EmailType", send})
	end
	for index, record in final do
		table.insert(form, {"HostName" .. index, record.Name})
		table.insert(form, {"RecordType" .. index, record.Type})
		table.insert(form, {"Address" .. index, record.Address})
		if record.Type == "MX" and record.MXPref then
			table.insert(form, {"MXPref" .. index, tostring(record.MXPref)})
		end
		if record.TTL then
			table.insert(form, {"TTL" .. index, tostring(record.TTL)})
		end
	end
	local response = call("changeDnsRecords", "namecheap.domains.dns.setHosts", {}, form)
	local result = requireResult("changeDnsRecords", response, "DomainDNSSetHostsResult")
	if scalar(result.attrs.IsSuccess or "") ~= true then
		return fail("changeDnsRecords", `{PROVIDER} did not apply the change to {name} (IsSuccess was not true); the zone should be unchanged, so read it before retrying`, 200, false)
	end

	local out: Plain = {Domain = name, Changed = true, Added = added, Updated = updated, Removed = #removed,
		Unchanged = unchanged, EmailType = send or current}
	local ok, after = pcall(readHosts, "changeDnsRecords", sld, tld)
	if not ok then
		out.Verified = false
		out.VerifyError = "The change was applied, but reading the records back failed; read them with getDnsRecords"
		out.Hosts = recordList(final)
		return out
	end
	local written: {Record} = {}
	for _, host in after.Hosts do
		table.insert(written, fromHost(host))
	end
	out.Verified = sameState(final, written)
	if not out.Verified then
		out.VerifyError = "The records read back differ from those written, possibly from a concurrent change; review them before changing again"
	end
	out.Hosts = recordList(written)
	return out
end

-- Exports ----------------------------------------------------------------

local exports: {[string]: any} = {
	listDomains = listDomains,
	getDomain = getDomain,
	checkAvailability = checkAvailability,
	getNameservers = getNameservers,
	getDnsRecords = getDnsRecords,
}
if houston.allows("data:write") then
	exports.changeDnsRecords = changeDnsRecords
end

local HELP: {[string]: string} = {
	listDomains = [[listDomains(options?) -> {Domains, TotalItems, CurrentPage, PageSize}
  Lists the account's domains, one page at a time. options: ListType ("ALL",
  "EXPIRING", "EXPIRED"), SearchTerm (up to 70 characters), Page (from 1),
  PageSize (10 to 100, default 20), SortBy ("NAME", "NAME_DESC", "EXPIREDATE",
  "EXPIREDATE_DESC", "CREATEDATE", "CREATEDATE_DESC"). Each domain is
  {ID, Name, User, Created, Expires, IsExpired, IsLocked, AutoRenew,
  WhoisGuard, IsPremium, IsOurDNS}; dates are Namecheap's MM/DD/YYYY text.
  Request the next Page while CurrentPage * PageSize < TotalItems.
  Example: namecheap.listDomains({ListType = "EXPIRING", SortBy = "EXPIREDATE"})]],
	getDomain = [[getDomain(domain) -> DomainGetInfoResult
  Details of one domain: Status, ID, DomainName, OwnerName, IsOwner,
  IsPremium, DomainDetails {CreatedDate, ExpiredDate, NumYears}, Whoisguard,
  PremiumDnsSubscription, DnsDetails {ProviderType, IsUsingOurDNS, HostCount,
  EmailType, Nameserver = {...}}, Modificationrights {All, Rights}. Auto-renew
  and lock state come from listDomains instead.
  Example: namecheap.getDomain("example.com")]],
	checkAvailability = [[checkAvailability(domains) -> {Results}
  Checks whether 1 to 50 domain names can be registered. Each result is
  {Domain, Available, IsPremiumName, PremiumRegistrationPrice,
  PremiumRenewalPrice, PremiumRestorePrice, PremiumTransferPrice, IcannFee,
  EapFee}. It registers nothing.
  Example: namecheap.checkAvailability({"example.com", "example.io"})]],
	getNameservers = [[getNameservers(domain) -> {Domain, IsUsingOurDNS, IsPremiumDNS, IsUsingFreeDNS, Nameservers}
  The domain's nameservers. When IsUsingOurDNS is false, DNS records are
  served elsewhere and the records shown by getDnsRecords are not in use.
  Example: namecheap.getNameservers("example.com")]],
	getDnsRecords = [[getDnsRecords(domain) -> {Domain, EmailType, IsUsingOurDNS, Hosts}
  The domain's DNS records in Namecheap DNS. Each host is {HostId, Name, Type,
  Address, MXPref, TTL, AssociatedAppTitle, FriendlyName, IsActive,
  IsDDNSEnabled}; Name is "@" for the domain itself; MXPref only matters for MX
  records. EmailType is the mail setting: NONE, MX (custom MX records), MXE
  (mail forwarding to an IP), FWD (Namecheap email forwarding), OX (Private
  Email) or GMAIL. Pass the registered domain, such as example.com or
  example.co.uk, not a subdomain.
  Example: namecheap.getDnsRecords("example.com")]],
	changeDnsRecords = [[changeDnsRecords(domain, change) -> {Domain, Changed, Added, Updated, Removed, Unchanged, EmailType, Verified, VerifyError?, Hosts}
  Adds and removes DNS records while keeping every other record. Namecheap
  only replaces a domain's whole record set, so this reads the records, applies
  the change, writes the full set, then reads it back and sets Verified.
  change = {
    add = {{Name, Type, Address, MXPref?, TTL?}, ...},  -- MXPref required for MX
    remove = {{Name?, Type?, Address?}, ...},          -- at least one field each
    EmailType = "MX"?,                                  -- only to switch mail mode
  }
  Type is A, AAAA, ALIAS, CAA, CNAME, MX, MXE, NS, TXT, URL, URL301 or FRAME.
  Name is the host part ("@", "www", "_dmarc"). TTL is 60 to 60000 seconds,
  default Namecheap's automatic 1799. URL, URL301 and FRAME addresses need a
  protocol such as https://. For CAA, copy the Address format getDnsRecords shows.
  Removals happen before additions, so remove and add the same Name and Type to
  replace a record. Each remove rule must match at least one record, or nothing
  is written. Adding a record that already exists changes only its TTL.
  Mail: MX records are kept only in EmailType MX and MXE records in MXE or MX;
  adding them switches a NONE, MX or MXE domain automatically. A domain on the
  FWD, OX or GMAIL mail setting is never switched unless EmailType is given,
  because that changes where its mail goes.
  The change fails when the domain uses other nameservers. A failed or
  interrupted call may already have applied; read the records before retrying.
  Example: namecheap.changeDnsRecords("example.com", {
    remove = {{Name = "www", Type = "CNAME"}},
    add = {{Name = "www", Type = "CNAME", Address = "example.netlify.app", TTL = 300}},
  })]],
}

function exports.help(): string
	local sections = {
		"namecheap: domains and DNS records of one Namecheap account. Connector calls return values directly; do not await them. "
			.. "Errors carry Namecheap's error number and message. Namecheap accepts calls only from the connection's whitelisted IP address.",
	}
	for _, name in {"listDomains", "getDomain", "checkAvailability", "getNameservers", "getDnsRecords", "changeDnsRecords"} do
		if exports[name] then
			table.insert(sections, HELP[name])
		end
	end
	return table.concat(sections, "\n\n")
end

return exports
