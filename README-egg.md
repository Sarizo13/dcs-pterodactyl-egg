# Egg Pterodactyl — DCS World Dedicated Server (Wine)

Serveur dédié DCS World sur Pterodactyl. DCS n'a **pas** de serveur dédié natif
Linux : les binaires Windows tournent sous Wine + Xvfb.

> **Lis la section [Compte ED / `network.vault`](#5-compte-ed--networkvault-étape-obligatoire)
> avant de commencer.** Le serveur n'acceptera aucun joueur tant que cette étape
> n'est pas faite, et elle demande une action interactive une seule fois.

---

## Sommaire

1. [Ce que contient ce dossier](#1-ce-que-contient-ce-dossier)
2. [Pourquoi une image dédiée](#2-pourquoi-une-image-dédiée-et-pas-limage-aterfax-telle-quelle)
3. [Construire et publier l'image](#3-construire-et-publier-limage)
4. [Importer l'egg et créer le serveur](#4-importer-legg-et-créer-le-serveur)
5. [Compte ED / `network.vault`](#5-compte-ed--networkvault-étape-obligatoire)
6. [Missions (SFTP)](#6-missions-sftp)
7. [Modules et terrains](#7-modules-et-terrains)
8. [Mises à jour et rollback](#8-mises-à-jour-et-rollback)
9. [Le pin Wine, en détail](#9-le-pin-wine-en-détail)
10. [Dépannage](#10-dépannage)
11. [Ce que je n'ai pas pu vérifier](#11-ce-que-je-nai-pas-pu-vérifier)

---

## 1. Ce que contient ce dossier

| Fichier | Rôle |
|---|---|
| `egg-dcs-world.json` | L'egg à importer dans le panel. **Généré** — ne l'édite pas à la main. |
| `Dockerfile` | L'image compatible Wings (Wine épinglé + Xvfb). |
| `entrypoint.sh` | Shim Pterodactyl : déplie `$STARTUP` et l'exécute. |
| `dcs-bootstrap.sh` | Préfixe Wine + install/update DCS. Partagé install ↔ runtime. |
| `dcs-server-run.sh` | Lanceur runtime (Xvfb, settings, logs, détection, arrêt propre). |
| `install.sh` | Script d'install, embarqué tel quel dans l'egg. |
| `build-egg.js` | Régénère `egg-dcs-world.json` depuis `install.sh`. |
| `validate-egg.js` | Valide la structure de l'egg. |
| `.github/workflows/build-image.yml` | Build + push GHCR des tags d'image. |

Après toute modification de `install.sh` :

```bash
node build-egg.js && node validate-egg.js
```

---

## 2. Pourquoi une image dédiée (et pas l'image aterfax telle quelle)

L'image `aterfax/dcs-world-dedicated-server` est excellente, mais elle **ne peut
pas** être utilisée directement comme `docker_image` d'un egg :

- Elle est basée sur `linuxserver/webtop` : son `ENTRYPOINT` est `/init`
  (s6-overlay), qui démarre un bureau XFCE et lance DCS via un service s6.
- **Wings ne définit ni `Entrypoint` ni `Cmd`** sur le conteneur qu'il crée. La
  startup command de l'egg n'arrive que par la variable d'environnement
  `$STARTUP`, et c'est à l'image de la déplier et de l'exécuter. C'est ce que la
  doc résume par *« Docker images must be specifically designed to work with
  Pterodactyl Panel »*.
  → l'image aterfax **ignorerait purement et simplement** la commande de l'egg.
- Les images linuxserver font du switch PUID/PGID **en root** au boot, alors que
  Wings lance le conteneur sous un UID non-root fixe.
- Seul `/home/container` est persistant sous Wings ; aterfax travaille dans
  `/config`.

Cette image est donc une reconstruction native Pterodactyl qui **reprend la
recette éprouvée d'aterfax** plutôt que d'en inventer une : les overrides DLL
(`wbemprox`, `msvcp140_atomic_wait`), la liste winetricks
(`d3dcompiler_43`, `d3dx11_43`, `d3dcompiler_47`, `win10`, `vcrun2022`), et toute
la séquence de bootstrap de `DCS_updater.exe` (y compris l'astuce
`DCS_updater_initial.exe` qui évite que l'updater se mette à jour par-dessus
lui-même) viennent de ce projet.

---

## 3. Construire et publier l'image

Pterodactyl ne sait que **tirer** une image, jamais la construire. Il faut donc
la publier sur un registre accessible depuis le nœud Wings.

### Via GitHub Actions (en place)

Ce dépôt est publié sur https://github.com/Sarizo13/dcs-pterodactyl-egg. Tout
push touchant le `Dockerfile` ou les scripts déclenche le workflow, qui
construit et pousse deux tags :

- `ghcr.io/sarizo13/dcs-world-server:wine-10.20` ← **recommandé**
- `ghcr.io/sarizo13/dcs-world-server:wine-11.10` ← plus récent, non validé

Le namespace est en **minuscules** : les registres refusent les majuscules dans
un nom d'image, alors que le compte GitHub s'écrit « Sarizo13 ». Le workflow
force la casse lui-même.

Après le premier build réussi, rends le package **public** :
profil → Packages → `dcs-world-server` → Package settings → Change visibility.
Il est privé par défaut et Wings ne pourra pas le tirer. À défaut, il faut
configurer des credentials de registre sur le nœud.

L'image ne contient **pas** DCS — seulement Wine, Xvfb et les scripts (~2 Go).
DCS est téléchargé pendant la phase d'install, dans le volume du serveur.

### À la main (si besoin)

```bash
docker build -t ghcr.io/sarizo13/dcs-world-server:wine-10.20 \
  --build-arg WINE_BRANCH=staging \
  --build-arg WINE_VERSION=10.20~bookworm-1 .
docker push ghcr.io/sarizo13/dcs-world-server:wine-10.20
```

### Puis, dans l'egg

Déjà fait : `egg-dcs-world.json` pointe sur `ghcr.io/sarizo13/...`. Si tu
changes de namespace, édite `IMAGE` dans `build-egg.js` puis relance
`node build-egg.js && node validate-egg.js`.

> **`CONTAINER_UID` / `CONTAINER_GID`** — l'image crée un utilisateur en UID 988
> (défaut Pterodactyl). Si ton `wings config.yml` utilise un autre
> `system.user.uid`, passe-le en `--build-arg CONTAINER_UID=` **et** ajuste les
> variables cachées du même nom dans l'egg. Ça compte : Wine nomme son
> répertoire utilisateur d'après l'entrée passwd de l'UID courant, donc un
> décalage entre phase d'install et phase runtime déplacerait le
> `Saved Games`.

---

## 4. Importer l'egg et créer le serveur

1. **Admin → Nests → Import Egg** → `egg-dcs-world.json`.
2. Crée le serveur.

### Ressources

| | |
|---|---|
| Disque | **Prévois large.** DCS + un terrain, c'est de l'ordre de la centaine de Go. Mets `0` (illimité) pour la première install. |
| RAM | 8 Go minimum, plutôt 16 Go avec du monde. |
| CPU | DCS est très sensible au monothread. |

Une install qui manque de place échoue **en fin de téléchargement**, après des
heures. Vérifie avant.

### Allocations

| Port | Protocole | Rôle | Obligatoire |
|---|---|---|---|
| `10308` | TCP **et** UDP | Port de jeu | Oui — allocation **primaire** |
| `8088` | TCP | WebGUI | Non |
| `5900` | TCP | VNC (login ED ponctuel) | Le temps de l'étape 5 |

L'allocation primaire alimente `SERVER_PORT`, que le script écrit dans
`serverSettings.lua`. Il n'y a **pas** de variable « port » dans l'egg : ce
serait une deuxième source de vérité qui finirait par diverger de l'allocation.

> Pterodactyl crée les allocations par port, sans distinction TCP/UDP : Wings
> publie les deux. Côté pare-feu hôte, **ouvre bien 10308 en TCP *et* UDP** —
> n'ouvrir que TCP est l'erreur classique (le serveur apparaît dans la liste
> mais personne ne peut jouer).

### Variables

| Variable | Défaut | Note |
|---|---|---|
| `DCS_BRANCH` | `release` | `openbeta` conservé pour le legacy ; ED a fusionné les branches en 2024. |
| `DCS_SERVER_NAME` | `DCS Server` | |
| `DCS_SERVER_PASSWORD` | *(vide)* | |
| `DCS_MAX_PLAYERS` | `16` | |
| `DCS_MODULES` | *(vide)* | Voir §7. Appliqué **à l'install**. |
| `DCS_AUTO_UPDATE` | `0` | Voir §8. |
| `DCS_MISSION` | *(vide)* | Voir §6. |
| `DCS_WEBGUI_PORT` | `8088` | |
| `DCS_MANAGE_SETTINGS` | `1` | `0` = le panel ne touche plus à `serverSettings.lua`. |
| `VNC_ENABLED` / `VNC_PORT` / `VNC_PASSWORD` | `0` / `5900` / vide | Voir §5. |
| `FORCE_REINSTALL` | `0` | **Destructif**, voir §8. |
| `DCS_READY_REGEX` | *(vide)* | Filet de sécurité, voir §10. |
| `DCS_STOP_TIMEOUT` | `90` | |

**Épingler Wine** se fait en changeant l'**image Docker** du serveur (menu
*Startup* → *Docker Image*), pas par une variable : Wine est installé au build.

### La première install est longue

Compte **une à plusieurs heures**. La barre du panel ne bouge pas ; regarde le
log d'installation, `dcs-bootstrap` affiche un `waiting for DCS updater… Ns`
toutes les 10 s. Ne l'annule pas.

Découpage voulu :

- **Phase install** (conteneur d'install, root, `/mnt/server`) : préfixe Wine,
  winetricks, téléchargement DCS, modules. Tout ce qui est lent et fragile.
- **Phase runtime** : démarre `DCS_server.exe`, rien d'autre.

Si `DCS_server.exe` manque au démarrage, `dcs-server-run` refait le bootstrap
lui-même en le signalant bruyamment — c'est un filet, pas le chemin normal.

---

## 5. Compte ED / `network.vault` (étape obligatoire)

**C'est le point qui bloque tout le monde.**

`DCS_server.exe` refuse de servir des joueurs tant que
`Saved Games/DCS.server/Config/network.vault` n'existe pas. Ce fichier contient
les credentials Eagle Dynamics enregistrés pour l'autologin.

Le projet aterfax le dit explicitement dans son service d'autostart :

> *Cannot autostart without user logging in and saving credentials for autologin.*

**Il n'existe aucun flag de login non-interactif documenté pour
`DCS_server.exe`.** C'est pour ça que cet egg n'expose pas de variables
`ED_USERNAME` / `ED_PASSWORD` : elles donneraient une fausse impression de
fonctionnement, et surtout elles stockeraient ton mot de passe ED en clair dans
la base du panel, visible de tout admin. Le vault reste dans le volume du
serveur, jamais dans l'egg.

### Procédure (une seule fois)

1. Panel → *Startup* : `VNC_ENABLED` = `1`, `VNC_PASSWORD` = un mot de passe.
2. Ajoute une allocation sur `5900` (ou mets `VNC_PORT` sur un port alloué).
3. Démarre le serveur.
4. Connecte-toi en VNC sur `<ip>:5900`. Tu vois l'affichage Xvfb sur lequel DCS
   tourne.
5. Connecte-toi avec ton compte ED, **coche « se souvenir / save credentials »**.
6. Arrête le serveur. Vérifie en SFTP que
   `saved-games/DCS.server/Config/network.vault` existe.
7. **Remets `VNC_ENABLED` = `0`** et retire l'allocation VNC.

> **Sécurité** : un VNC sans mot de passe sur un port public donne le contrôle
> total du conteneur. Le script te le dit dans la console, mais ne compte pas
> dessus — mets un mot de passe et désactive-le après.

### Sauvegarde-le

Récupère `network.vault` en SFTP et garde-le. Après un `FORCE_REINSTALL` tu
pourras le redéposer au lieu de refaire toute la manip VNC.

> **Non vérifié** : je ne sais pas si `network.vault` est lié à la machine ou au
> préfixe Wine. Le remettre dans le **même** serveur après réinstall devrait
> marcher ; le copier vers une autre machine ou un autre préfixe est à tester —
> si le serveur redemande un login, refais la procédure VNC.

---

## 6. Missions (SFTP)

Connecte-toi en SFTP avec les identifiants du panel. Dépose les `.miz` dans :

```
saved-games/DCS.server/Missions/
```

`saved-games` est un lien symbolique créé au démarrage vers le vrai
`Saved Games` du préfixe Wine. Il est là précisément parce que le chemin réel
dépend du nom d'utilisateur Wine (`.wine/drive_c/users/<user>/Saved Games`),
lui-même dépendant de l'UID. Le lien reste valable même si l'UID change.

Le nom `DCS.server` vient de `DCS_WRITE_DIR`, passé à `DCS_server.exe` via `-w`.
Il est **forcé** plutôt que laissé au défaut : ED a renommé ce dossier plusieurs
fois (`DCS.openbeta_server` → `DCS.release_server` → `DCS.server` →
`DCS.dcs_serverrelease` selon les versions), et `-w` met fin à cette dérive.

### Charger une mission au démarrage

Mets le nom du fichier dans `DCS_MISSION` (ex. `training.miz`) — juste le nom,
pas le chemin. Au boot, le script :

1. vérifie que le fichier existe dans `Missions/` (sinon : warning, et il
   ignore) ;
2. convertit le chemin en chemin Windows via `winepath -w` ;
3. remplace le bloc `["missionList"]` de `serverSettings.lua`.

Laisse `DCS_MISSION` vide pour garder la liste gérée depuis la WebGUI.

### Fichiers écrasés à chaque boot

Avec `DCS_MANAGE_SETTINGS=1` (défaut), ces clés de `serverSettings.lua` sont
réappliquées **à chaque démarrage** depuis le panel :

`name`, `password`, `maxPlayers`, `port`, `webgui_port`

Tout le reste (options avancées, listes, etc.) est préservé. C'est nécessaire
parce que DCS réécrit `serverSettings.lua` en sortant. Si tu préfères tout gérer
depuis la WebGUI, mets `DCS_MANAGE_SETTINGS=0`.

---

## 7. Modules et terrains

`DCS_MODULES` est une liste séparée par des espaces, appliquée **pendant la
phase d'install** :

```
SYRIA_terrain MARIANAISLANDS_terrain SUPERCARRIER
```

| Terrain | ID |
|---|---|
| Caucasus | `CAUCASUS_terrain` |
| Nevada | `NEVADA_terrain` |
| Normandy 1944 | `NORMANDY_terrain` |
| Persian Gulf | `PERSIANGULF_terrain` |
| The Channel | `THECHANNEL_terrain` |
| Syria | `SYRIA_terrain` |
| Mariana Islands | `MARIANAISLANDS_terrain` |
| South Atlantic | `FALKLANDS_terrain` |
| Sinai | `SINAIMAP_terrain` |
| Kola | `KOLA_terrain` |
| Afghanistan | `AFGHANISTAN_terrain` |
| Iraq | `IRAQ_terrain` |
| Germany Cold War | `GERMANYCW_terrain` |
| Marianas WWII | `MARIANAISLANDSWWII_terrain` |
| Supercarrier | `SUPERCARRIER` |
| WWII Units pack | `WWII-ARMOUR` |

*(Liste issue du module installer d'aterfax. ED en ajoute : un ID inconnu fait
échouer l'updater sur ce module.)*

### Ajouter un terrain après coup

Sans repasser par une réinstall complète — via la console du panel, serveur
arrêté, ce n'est pas possible (la console n'est branchée que sur le process de
jeu). Le chemin propre :

1. Ajoute l'ID à `DCS_MODULES`.
2. **Reinstall** depuis le panel avec `FORCE_REINSTALL=0`.

Avec `FORCE_REINSTALL=0`, le préfixe Wine et l'install DCS existants sont
conservés : `dcs-bootstrap` saute les étapes déjà faites (marqueur
`.wine/.dcs-prereqs-done`) et ne fait que l'update + l'ajout des modules
manquants. Tes missions et ton `network.vault` survivent.

> **Modules payants** : posséder le terrain sur le compte ED utilisé au §5 est
> nécessaire. Le téléchargement lui-même ne demande pas d'identifiants —
> c'est le `network.vault` qui porte l'autorisation à l'exécution.
> **Non vérifié faute de panel réel** : je n'ai pas pu tester l'installation
> d'un terrain payant de bout en bout.

---

## 8. Mises à jour et rollback

### Pourquoi `DCS_AUTO_UPDATE=0` par défaut

Une update DCS peut durer des heures et peut casser une install qui marchait. En
auto, tu découvres ça pendant un reboot planifié, serveur indisponible et sans
moyen simple de revenir en arrière. Mets `1` seulement si tu acceptes ce risque.

### Mettre à jour volontairement

1. **Sauvegarde d'abord** (voir plus bas).
2. `DCS_AUTO_UPDATE` = `1`, démarre, laisse l'update se faire.
3. Remets `DCS_AUTO_UPDATE` = `0`.

### Sauvegarder ce qui compte

Avant toute update ou réinstall, récupère en SFTP :

```
saved-games/DCS.server/Config/        <- network.vault + serverSettings.lua
saved-games/DCS.server/Missions/      <- tes .miz
```

C'est petit, et ça t'évite de refaire la procédure VNC.

### Rollback

| Situation | Quoi faire |
|---|---|
| **Une update Wine casse tout** | Le plus simple : *Startup* → *Docker Image* → reprends `wine-10.20`, redémarre. C'est tout l'intérêt d'avoir plusieurs tags. Wine est épinglé **et** `apt-mark hold` dans l'image, donc rien ne bouge tout seul. |
| **Une update DCS casse tout** | DCS ne propose pas de downgrade propre côté serveur dédié. Restaure une sauvegarde du volume si ton hébergeur en fait, sinon réinstall complète (ci-dessous). |
| **Install corrompue** | `FORCE_REINSTALL=1` → Reinstall → **remets `FORCE_REINSTALL=0`**. |

> `FORCE_REINSTALL=1` supprime le préfixe Wine **entier**, donc l'install DCS,
> tes missions et `network.vault`. Sauvegarde avant. Et remets-le à `0` juste
> après, sinon la prochaine réinstall repartira de zéro sans prévenir.

---

## 9. Le pin Wine, en détail

**Le problème n'est pas « Wine 11.0 casse l'updater ».** La régression réelle est
plus ancienne et plus large :

> Depuis **Wine 10.3**, `DCS_updater.exe` détecte à tort un debugger et refuse de
> démarrer :
> *« A debugger has been found running in your system. Please, unload it from
> memory and restart your program. »*
> **`DCS_server.exe` n'est pas affecté.**

- Bugs WineHQ [58043](https://bugs.winehq.org/show_bug.cgi?id=58043) et
  [59074](https://bugs.winehq.org/show_bug.cgi?id=59074)
- Suivi : [ActiumDev/dcs-server-wine#8](https://github.com/ActiumDev/dcs-server-wine/issues/8)
  (ouvert, créé le 06/12/2025, toujours ouvert)

**Le correctif documenté est `wine-staging`**, pas une version particulière.
C'est vicieux : comme seul l'updater est touché, une image en Wine « stable
récent » **s'installe une fois correctement** puis casse au premier update.

Ce que fait cette image :

- `wine-staging` (jamais `winehq-stable`), épinglé à `10.20~bookworm-1` —
  dernière 10.x, donc antérieure au basculement **ntsync** de Wine 11.0 ;
- les 4 paquets Wine sont `apt-mark hold` : pas de dérive silencieuse ;
- le pin est écrit dans `/etc/dcs-wine-pin` et affiché dans la bannière console ;
- si l'image n'est pas staging, `dcs-server-run` **avertit au démarrage**, avant
  que ça ne morde.

**ntsync** : il faut `/dev/ntsync`, que Wings n'expose pas au conteneur. Le
risque est donc inerte ici — mais il n'y a aucune raison de le courir.

**Xvfb est non négociable** : `DCS_updater.exe` ne démarre pas sans display, et
`winetricks vcrun2022` en exige un même en `--unattended`. `dcs-bootstrap` et
`dcs-server-run` attendent tous deux l'apparition du socket `/tmp/.X11-unix/X99`
au lieu d'un `sleep` — c'est une source classique de « could not open display »
en plein milieu de winetricks.

---

## 10. Dépannage

**Le serveur reste « starting » indéfiniment**

`dcs-server-run` n'affiche `>>> DCS SERVER READY <<<` que quand le port de jeu
est effectivement bindé. S'il ne vient jamais :

- cause n°1 : `network.vault` manquant (§5) — le warning est dans la console ;
- après 10 min, le script affiche un rappel dans le log ;
- filet : mets un motif egrep dans `DCS_READY_REGEX`, matché contre `dcs.log`.
  Il est vide par défaut parce que le libellé exact des lignes de log DCS change
  entre versions et que je n'ai pas pu le vérifier sur un vrai serveur — la
  détection par port ne dépend, elle, d'aucun libellé.

**`A debugger has been found running in your system`**

Ton image n'est pas en `wine-staging`. Voir §9. Rebuild.

**Console vide**

DCS écrit dans `Logs/dcs.log`, pas sur stdout ; Wings ne lit que stdout. Le
script fait un `tail -F` du log vers la console. Si c'est vide, c'est que le log
n'existe pas encore → DCS n'a pas démarré : regarde les lignes `[dcs]`.

**`could not open display` / winetricks bloqué**

Xvfb n'est pas parti. Vérifie `Xvfb` dans l'image et le socket
`/tmp/.X11-unix/X99`.

**Les missions n'apparaissent pas**

Vérifie que tu es bien dans `saved-games/DCS.server/Missions/` et que
`DCS_WRITE_DIR` vaut toujours `DCS.server`.

**Le serveur n'apparaît pas dans la liste multijoueur**

`network.vault` (§5), puis pare-feu : 10308 en **UDP aussi**.

---

## 11. Ce que je n'ai pas pu vérifier

### Validé en production depuis

Premier déploiement réel sur le panel, le 02/08/2026 :

| Point | Résultat |
|---|---|
| **Build de l'image** | ✅ Passe. Wine `10.20 (Staging)` confirmé dans le conteneur. |
| **Préfixe Wine + winetricks** | ✅ Les 5 composants s'installent, `vcrun2022` inclus — c'est celui qui exige un vrai display, donc Xvfb est validé de bout en bout. |
| **Import de l'egg** | ✅ Importé, serveur créé, variables prises en compte. |
| **Téléchargement DCS** | ✅ L'updater télécharge après correction (voir ci-dessous). |

**Deux bugs trouvés en production, corrigés :**

1. **`bash: /mnt/install/install.sh: Permission denied`** — la phase d'install
   se terminait en quelques secondes sans exécuter une ligne. L'image déclarait
   `USER container`, or Wings ne fixe pas `User` sur le conteneur d'install
   (contrairement au conteneur de jeu) et écrit le script en root/0644. Cause
   racine : une seule image pour deux rôles que Wings traite différemment.
   La directive `USER` a été retirée ; un smoke-test vérifie désormais que
   l'UID par défaut de l'image est bien 0.

2. **L'updater échouait au premier passage.** Sur un préfixe neuf, la première
   invocation de `DCS_updater.exe` ne fait que mettre à jour l'updater lui-même
   puis se termine en quelques secondes, sans rien télécharger. Je traitais
   l'absence de `DCS_server.exe` après cette passe comme fatale. `do_update()`
   boucle maintenant sur plusieurs passes et remonte `autoupdate_log.txt` —
   une passe en échec était auparavant totalement muette.

### Ce qui reste à valider

| Point | Statut |
|---|---|
| **Détection de démarrage** | La sentinelle est émise par mon script, donc déterministe — mais la sonde « port bindé » (`ss`) n'a pas été testée contre un vrai DCS. |
| **Arrêt propre** | `wineserver -k15` puis `-k`. Je n'ai pas pu vérifier que DCS flushe bien son état sur SIGTERM. |
| **`network.vault`** | Le mécanisme est confirmé par le code d'aterfax. La portabilité du fichier entre machines/préfixes n'est **pas** vérifiée. |
| **Terrains payants** | Le flux `DCS_updater.exe install <ID>` vient d'aterfax. Non testé de bout en bout avec un module payant. |
| **UID ≠ 988** | Le code gère le cas (création d'entrée passwd, résolution dynamique du dossier Wine, symlink stable). Non testé. |

En revanche, testés localement et corrigés suite à ces tests :

- réécriture du bloc `["missionList"]` par comptage d'accolades (multi-lignes,
  clés avant/après préservées, accolades équilibrées) ;
- échappement Lua des chemins Windows — **un bug réel a été trouvé et corrigé** :
  `awk -v` réinterprète les séquences d'échappement et transformait
  `Missions\test.miz` en `Missions<TAB>est.miz`. Le bloc passe maintenant par
  `ENVIRON`, qui est littéral ;
- réconciliation de `serverSettings.lua` — **deuxième bug réel corrigé** : les
  `sed` d'origine n'échappaient que pour Lua, pas pour `sed` lui-même ; un nom de
  serveur contenant `&`, `/` ou `\` corrompait le fichier. Remplacés par un
  setter awk. Validé avec `Team A & B / "Elite" \ Squad`.

---

## Sources

- [Aterfax/DCS-World-Dedicated-Server-Docker](https://github.com/Aterfax/DCS-World-Dedicated-Server-Docker) — recette Wine/DCS réutilisée
- [ActiumDev/dcs-server-wine#8](https://github.com/ActiumDev/dcs-server-wine/issues/8) — régression updater ≥ Wine 10.3
- [WineHQ 58043](https://bugs.winehq.org/show_bug.cgi?id=58043) · [59074](https://bugs.winehq.org/show_bug.cgi?id=59074)
- [Pterodactyl — Creating a Custom Egg](https://pterodactyl.io/community/config/eggs/creating_a_custom_egg.html)
- [DCS World Dedicated Server (ED)](https://www.digitalcombatsimulator.com/en/downloads/world/server/)
