You need a Namecheap account with API access, and the IPv4 address Houston
connects to Namecheap from. No developer app is required.

1. Ask Houston for the IPv4 address its servers use to connect to other
   services. Namecheap answers only requests from addresses you whitelist.
2. Sign in to [Namecheap](https://www.namecheap.com) and open **Profile** >
   **Tools**. Under **Business & Dev Tools**, select **Manage** next to
   **Namecheap API Access**.
3. Turn API access on and accept the terms. Namecheap enables it only for
   accounts that meet its
   [requirements](https://www.namecheap.com/support/api/intro/); if the switch
   isn't available, contact Namecheap support.
4. Under **Whitelisted IPs**, select **Edit**, then **Add IP**. Enter
   Houston's address and select **Save Changes**.
5. Copy your **API key** from the same page.
6. In Houston, choose the access level. Keep **Environment** on **Production**.
7. Enter your **Namecheap username**, the **Whitelisted IP address** from step
   1, and the **API key**.
8. Select **Add connector**.

Your API key stays on the Houston server.

## Advanced

### Access levels

**Read** lets agents read your domains and DNS records. **Write** also lets them
add, update and remove DNS records. Neither level
can register, renew or transfer domains, or change nameservers, contacts or
privacy settings.

DNS changes only work for domains that use Namecheap's own nameservers. For a
domain pointed at another DNS provider, change its records there.

### Sandbox

To try the connector without touching real domains, create an account on
[sandbox.namecheap.com](https://www.sandbox.namecheap.com), turn on its API
access and whitelist Houston's address there, then choose **Sandbox** as the
**Environment**. Sandbox accounts and API keys are separate from production.

### Troubleshooting

- **"Invalid request IP" or a similar IP error.** The address isn't whitelisted
  in Namecheap, or it isn't the one Houston connects from. Check both match the
  **Whitelisted IP address** setting.
- **"API Key is invalid or API access has not been enabled".** Copy the API
  key again, and check that API access is still on.
- **A domain isn't found.** Use the registered domain, such as `example.com`,
  rather than a subdomain, and check that it belongs to this Namecheap account.
