# Base Sepolia — artefacts de déploiement (désactivé V1)

**Statut : désactivé pour V1, conservé comme référence.**

Ce dossier contenait les artefacts de la dry-run Base Sepolia du 2026-04-21,
faite alors que V1 visait un déploiement 5-chain. Le pivot documenté dans
[ADR-0011](../../../docs/adr/0011-v1-arbitrum-first.md) (2026-04-22) restreint
V1 à **Arbitrum One mainnet** (chainid 42161) et **Arbitrum Sepolia testnet**
(chainid 421614). Base Sepolia n'est plus un target V1.

## Que faire du contenu ?

- `.env.base-sepolia` (gitignored) : **ne pas réutiliser**. Les clés de
  déploiement étaient des EOAs éphémères pour dry-run, jamais portées en
  mainnet ; elles peuvent être supprimées.
- Tout script ou broadcast qui référencerait ce dossier va échouer en V1 :
  `DeployCore.s.sol` et `DeployPeripherals.s.sol` contiennent un guard
  `require(block.chainid == 42_161 || block.chainid == 421_614)` qui
  abortera sur chainid 84532.

## Réactivation ultérieure ?

Base Sepolia pourrait redevenir un target utile le jour où V2 active le
déploiement multi-chain (cf. [ADR-0012](../../../docs/adr/0012-v2-cross-chain-subscription-receipts.md)).
À ce moment-là, les scripts de déploiement devront être élargis à la liste
de chainids V2 retenue, et ce dossier pourra être renommé ou recréé à
partir d'un `env.template` à jour.

## Historique

- 2026-04-21 : dry-run Base Sepolia préparée (voir `docs/operations/testnet-private.md`
  historique si conservé).
- 2026-04-22 : pivot ADR-0011, dossier marqué désactivé V1.
