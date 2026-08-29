# Maya Failover Controller

Controller for the user's own Maya1/Maya3 infrastructure. It monitors the primary Iran endpoints and switches the existing Cloudflare DNS A records to pre-provisioned spare Iran endpoints only after repeated health failures and a verified healthy spare.

Initial deployment target: management server 88.216.70.225.
