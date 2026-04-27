# Security Policy

## Overview

Sepehr is a non-custodial liquidation protection protocol for DeFi 
positions on Arbitrum. Smart contracts manage user-delegated 
authority (not custody) to execute flash loan rescues. Security is 
the foundational priority of the protocol.

## Reporting a Vulnerability

If you discover a vulnerability in Sepehr, please **do not open a 
public GitHub issue**. Instead, report it privately:

- **Email**: security@sepehr.app (or hello@sepehr.app with subject 
  prefix `[SECURITY]` if you can't use the security address)

For sensitive reports, encrypt with our PGP key:

- **Fingerprint**: `7EC0 1129 1D13 9993 6C3E  CE6D D5F2 52B5 C3F0 F43A`
- **Public key**: [docs/security/sepehr-pgp.asc](docs/security/sepehr-pgp.asc)
- **Recipient**: security@sepehr.app

We commit to:
- Acknowledging receipt within 48 hours
- Providing a triage assessment within 5 business days
- Engaging respectfully with security researchers throughout the 
  process

## Scope

In scope:
- Smart contracts under `src/` (SepehrCore, SepehrTimelock, the 
  three V1-registered adapters, libraries, interfaces, DEX 
  routers, flash loan providers)
- Deployment scripts under `script/` insofar as they affect on-chain 
  state of the V1 deployment

Out of scope:
- Mock contracts (`src/mocks/`, `test/helpers/Mock*.sol`) — these 
  are test utilities, not production code, per standard DeFi audit 
  convention (cf. Morpho Blue, Aave V3 Core)
- Third-party protocols (Aave V3, Compound V3, Morpho Blue, 
  Arbitrum) — please report directly to those teams
- Off-chain components (keeper, frontend, extension) — these live 
  in a separate private monorepo and have their own security 
  process
- Phishing or social engineering against Sepehr team or users
- Code in `audit/` branches not deployed to production

## Bug Bounty

A formal bug bounty program will be launched following the external 
security audit. Researchers contributing in the interim will be 
acknowledged in a public security hall of fame.

## Audit History

- Internal review: completed
- External audit: pending Arbitrum Audit Program candidacy 
  (timeline TBD)
- Public audit reports will be published in `docs/audits/` once 
  available.

## Disclosure Policy

Sepehr Labs follows responsible disclosure principles and will 
coordinate with researchers on:
- Determining the impact and severity of issues
- Developing a fix and deployment plan
- Coordinating the public disclosure timing

## Contact

- Security: security@sepehr.app (PGP-encrypted reports preferred)
- General: hello@sepehr.app
