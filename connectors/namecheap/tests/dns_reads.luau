-- DNS, nameserver, domain detail and availability reads parse Namecheap's XML, including escaped values.
local function xml(body: string): string
	return '<?xml version="1.0" encoding="utf-8"?><ApiResponse Status="OK" xmlns="http://api.namecheap.com/xml.response"><Errors />'
		.. '<!-- served by PHX01 --><CommandResponse Type="x">' .. body .. '</CommandResponse></ApiResponse>'
end

local RESPONSES = {
	["namecheap.domains.dns.getHosts"] = xml('<DomainDNSGetHostsResult Domain="example.co.uk" EmailType="MX" IsUsingOurDNS="true">'
		.. '<host HostId="11" Name="@" Type="A" Address="192.0.2.10" MXPref="10" TTL="1799" AssociatedAppTitle="" FriendlyName="" IsActive="true" IsDDNSEnabled="false" />'
		.. '<host HostId="12" Name="@" Type="TXT" Address="v=spf1 include:_spf.example.net &gt; ~all &amp; &quot;q&quot; &#233;&#x263A;" MXPref="10" TTL="300" IsActive="true" />'
		.. '<host HostId="13" Name="@" Type="MX" Address="mx1.example.net." MXPref="5" TTL="1799" IsActive="true"></host>'
		.. "<host HostId='14' Name='_dmarc' Type='TXT' Address='v=DMARC1; p=none; rua=mailto:a@example.com' MXPref='10' TTL='1799' IsActive='true'/>"
		.. '</DomainDNSGetHostsResult>'),
	["namecheap.domains.dns.getList"] = xml('<DomainDNSGetListResult Domain="example.co.uk" IsUsingOurDNS="false" IsPremiumDNS="false" IsUsingFreeDNS="false">'
		.. '<Nameserver>ns1.example.net</Nameserver><Nameserver>ns2.example.net</Nameserver></DomainDNSGetListResult>'),
	["namecheap.domains.getInfo"] = xml('<DomainGetInfoResult Status="Ok" ID="101" DomainName="example.co.uk" OwnerName="ada" IsOwner="true" IsPremium="false">'
		.. '<DomainDetails><CreatedDate>03/01/2020</CreatedDate><ExpiredDate>03/01/2027</ExpiredDate><NumYears>0</NumYears></DomainDetails>'
		.. '<Whoisguard Enabled="True"><ID>53536</ID><ExpiredDate>03/01/2027</ExpiredDate></Whoisguard>'
		.. '<DnsDetails ProviderType="FREE" IsUsingOurDNS="true" HostCount="4" EmailType="MX" DynamicDNSStatus="false" IsFailover="false">'
		.. '<Nameserver>dns1.registrar-servers.com</Nameserver></DnsDetails>'
		.. '<Modificationrights All="true"><Rights Type="dns">OK</Rights></Modificationrights></DomainGetInfoResult>'),
	["namecheap.domains.check"] = xml('<DomainCheckResult Domain="example.com" Available="false" ErrorNo="0" Description="" IsPremiumName="false" PremiumRegistrationPrice="0" PremiumRenewalPrice="0" PremiumRestorePrice="0" PremiumTransferPrice="0" IcannFee="0" EapFee="0.0" />'
		.. '<DomainCheckResult Domain="example-new.io" Available="true" ErrorNo="0" Description="" IsPremiumName="true" PremiumRegistrationPrice="13000.0000" PremiumRenewalPrice="40.84" PremiumRestorePrice="65.00" PremiumTransferPrice="40.84" IcannFee="0.18" EapFee="0.0" />'),
}

return {
	scenario = {publisher = {}, auth_method = "token", auth_config = {token = "fixture-key"},
		config = {api_host = "api.namecheap.com", username = "ada", client_ip = "203.0.113.7"}},
	configure = function()
		requests = {}
		http = {request = function(req)
			table.insert(requests, req)
			local command = string.match(req.url, "[?&]Command=([^&]+)")
			local body = RESPONSES[command]
			assert(body, "unexpected command " .. tostring(command))
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(body)})
		end}
	end,
	run = function(namecheap)
		assert(namecheap.changeDnsRecords == nil, "access defaults to Read")

		local zone = namecheap.getDnsRecords("Example.CO.UK.")
		assert(string.find(requests[1].url, "&Command=namecheap.domains.dns.getHosts&SLD=example&TLD=co.uk", 1, true), requests[1].url)
		assert(zone.Domain == "example.co.uk" and zone.EmailType == "MX" and zone.IsUsingOurDNS == true)
		assert(#zone.Hosts == 4)
		local a, txt, mx, dmarc = zone.Hosts[1], zone.Hosts[2], zone.Hosts[3], zone.Hosts[4]
		assert(a.HostId == 11 and a.Name == "@" and a.Type == "A" and a.Address == "192.0.2.10" and a.TTL == 1799 and a.IsActive == true)
		assert(txt.Address == 'v=spf1 include:_spf.example.net > ~all & "q" ' .. utf8.char(233) .. utf8.char(0x263A), txt.Address)
		assert(mx.MXPref == 5 and mx.Address == "mx1.example.net.")
		assert(dmarc.Name == "_dmarc" and dmarc.Address == "v=DMARC1; p=none; rua=mailto:a@example.com", "single-quoted attributes")

		local ns = namecheap.getNameservers("example.co.uk")
		assert(ns.IsUsingOurDNS == false and #ns.Nameservers == 2 and ns.Nameservers[2] == "ns2.example.net")

		local info = namecheap.getDomain("example.co.uk")
		assert(string.find(requests[3].url, "&Command=namecheap.domains.getInfo&DomainName=example.co.uk", 1, true))
		assert(info.ID == 101 and info.IsOwner == true and info.DomainName == "example.co.uk")
		assert(info.DomainDetails.ExpiredDate == "03/01/2027" and info.DomainDetails.NumYears == 0)
		assert(info.Whoisguard.Enabled == true and info.Whoisguard.ID == 53536)
		assert(info.DnsDetails.EmailType == "MX" and info.DnsDetails.HostCount == 4)
		assert(#info.DnsDetails.Nameserver == 1 and info.DnsDetails.Nameserver[1] == "dns1.registrar-servers.com", "a single nameserver stays an array")
		assert(#info.Modificationrights.Rights == 1 and info.Modificationrights.Rights[1].Type == "dns" and info.Modificationrights.Rights[1].Value == "OK")

		local check = namecheap.checkAvailability({"example.com", "EXAMPLE-NEW.io"})
		assert(string.find(requests[4].url, "&DomainList=example.com%2Cexample-new.io", 1, true), requests[4].url)
		assert(#check.Results == 2)
		assert(check.Results[1].Available == false and check.Results[2].Available == true)
		assert(check.Results[2].IsPremiumName == true and check.Results[2].PremiumRegistrationPrice == 13000 and check.Results[2].IcannFee == 0.18)
		assert(#requests == 4)
	end,
}
