# Commands

## Install upstream DFR on two lab Debian 12 VPSs
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/main/install.sh) v2.1.0
```

## Inspect native DFR state before shielding
```bash
ip -d link show type xfrm || true
ip xfrm state
ip xfrm policy
systemctl --no-pager --type=service | grep -Ei 'dragon|strongswan|charon'
ss -lunp | grep -E ':(500|4500)\\b' || true
```

## Do not enable Shielded mode yet
The carrier binary is not committed because XFRM/CHILD_SA endpoint behavior still needs end-to-end validation against upstream DFR.
