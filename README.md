# Relay

Relay est une app de barre des menus pour macOS qui partage **une enceinte ou un casque Bluetooth entre plusieurs Mac** (et un iPhone), même quand l’appareil n’accepte qu’une seule connexion à la fois.

Un clic sur l’icône ouvre un menu natif : on choisit le Mac qui doit avoir l’enceinte, ou « Aucun Mac » pour la laisser à l’iPhone. Un clic droit la passe à l’appareil suivant : chaque Mac à tour de rôle, puis l’iPhone (« Aucun Mac »), puis on recommence.

- macOS 14 ou plus récent, Swift 6, aucune dépendance externe
- Distribution hors App Store (Developer ID + notarisation), code compatible sandbox

## Utilisation

1. Appairez l’enceinte **une fois** avec chaque Mac (Réglages Système › Bluetooth).
2. Installez et ouvrez Relay sur chaque Mac. L’assistant guide pas à pas : Bluetooth, choix de l’enceinte, nom et icône du Mac, appairage des autres Mac avec un code à 6 chiffres, lancement au démarrage, test.
3. Ensuite, tout se passe dans la barre des menus.

La fenêtre **Aide et prérequis** vérifie tout en direct (permissions, enceinte appairée, réseau local, Mac joignables, lancement au démarrage). Elle propose une action pour chaque point en échec et permet de copier les logs.

## Compiler

Ouvrez `Relay.xcodeproj` et lancez le schéma **Relay**, ou :

```sh
xcodebuild -project Relay.xcodeproj -scheme Relay build
```

## Tests

```sh
Scripts/selftest.sh           # signature, anti-rejeu, appairage (bon et mauvais code)
Scripts/selftest.sh --group   # + deux instances réelles via Bonjour
```

Le mode `--group` démarre deux instances isolées dans un même processus. Il vérifie la découverte, l’appairage, le heartbeat, la synchronisation du nom et de l’enceinte, un ordre de connexion à distance, le verrouillage et le retrait d’un Mac. Il utilise une fausse adresse d’enceinte : aucun appareil réel n’est touché.

En Debug, `Relay --snapshots` produit une capture de chaque fenêtre en clair et en sombre dans le dossier temporaire de l’app.

## Publier

```sh
xcrun notarytool store-credentials relay-notary --apple-id <apple-id> --team-id 82FKKV622Q   # une seule fois
Scripts/release.sh
```

## Architecture

| Élément | Rôle |
|---|---|
| `Speaker/SpeakerController` | IOBluetooth : appareils appairés, connexion (3 tentatives), déconnexion vérifiée, notifications. CoreAudio (`AudioOutput`) : force la sortie par défaut. |
| `Network/PeerService` | Bonjour (`_speakerswitch._tcp`), liens TCP vers les membres, requête/réponse, heartbeat, reconnexion. |
| `Network/Wire` | Messages JSON avec préfixe de longueur, signés HMAC-SHA256, horodatage et nonce contre le rejeu. |
| `Network/Pairing` | Appairage : échange Curve25519 confirmé chiffre par chiffre avec engagements, clé du groupe transmise chiffrée (ChaChaPoly). |
| `Coordinator/SwitchCoordinator` | Machine à états de la bascule, mode verrouillé, diffusion d’état, gestion du groupe. |
| `Core/Store` | Réglages en `Codable` (UserDefaults), secret du groupe dans le Trousseau. |
| `UI/` | `StatusItemController` (NSMenu natif), onboarding, aide, réglages, design system SwiftUI (langage visuel boardui). |

### Bascule vers un Mac X

1. Le Mac qui a reçu le clic envoie `release(lock: true)` à tous les autres Mac en ligne, et libère lui-même l’enceinte s’il n’est pas X.
2. Il attend les accusés de réception (5 s).
3. Il connecte en local si X est ce Mac, sinon il envoie `connect` à X.
4. Chaque Mac diffuse son état ; tous les menus se mettent à jour.

Un Mac qui a reçu `release` est **verrouillé** : si macOS reconnecte l’enceinte de lui-même, Relay la déconnecte aussitôt. Le verrou saute quand ce Mac devient la cible.

### Protocole (pour une future app iOS)

Les échanges se font en TCP, trame par trame : 4 octets de longueur en big-endian, puis `{"message": <JSON en base64>, "mac": <HMAC-SHA256 en base64>}`. Un message contient `id`, `sender`, `timestamp`, `nonce`, `replyTo` et `body`. Les commandes sont `status`, `state`, `release`, `connect`, `result`, `groupUpdate`, `groupSyncRequest`, `removed` et `leave`, plus les messages d’appairage. Rien n’est propre à macOS : un client iOS pourra reprendre le même protocole.
