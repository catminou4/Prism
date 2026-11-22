# Audit Prism — bugs et optimisations

> Réalisé le 2026-11-21/22 par 5 agents d'audit en parallèle (un par module) + `swift test`.
> Périmètre : `Packages/PrismKit/Sources/` (~30 000 lignes) — PrismCore, PrismData, PrismDesign,
> PrismPlayer, PrismUI, PrismTools. Chaque finding a été tracé jusqu'à ses appelants.
>
> **État au moment de l'audit** : build vert (`swift build` + `xcodebuild`), 270 tests passent,
> zéro force unwrap sur données externes. Le code est édité en continu : les numéros de ligne
> peuvent avoir dérivé, les symboles restent valides.

## Bugs critiques

### 1. Boucle infinie dans le parser M3U — import gelé à jamais — ✅ corrigé (22/11, test `strayEqualsSignsDoNotStallTheScan`)

`Sources/PrismCore/Parsing/M3UParser.swift` — `ParserState.parseAttributes(_:_:into:stopAtComma:)`

Quand `=` apparaît là où une clé est attendue (`#EXTINF:-1 tvg-id="a"="b",Nom`, `#EXTM3U foo=`,
`tvg-id="a"=x`), le scan de clé ne progresse pas (`keyEnd == keyStart`), le `guard` échoue et
`continue` reboucle **sans avancer `p`** → boucle infinie. `CatalogRepository.parsePlaylist`
l'appelle via `@concurrent` sans timeout : une seule ligne malformée gèle l'import et brûle un
thread du cooperative pool.

**Fix** : dans le `else` du guard, avancer `p` d'au moins 1 (`p += 1`) avant `continue`.

### 2. `VLCEngine.pause()` est un no-op sur le live et pendant le chargement

`Sources/PrismPlayer/Engine/VLCEngine.swift:112-115`

```swift
func pause() {
    wantsPlay = false
    if player.canPause { player.pause() }
}
```

`canPause` (libvlc) est **toujours faux pour les streams live** et faux pendant l'ouverture :

- **Live** : pause → `playRequested=false`, phase `.paused`, mais VLC continue de décoder →
  l'UI ment.
- **VOD pendant `.loading`** : pause → VLC atteint `.playing` → `report(.playing)` ignoré car
  `playRequested=false` → **aucun `.paused` n'arrive → phase coincée à `.loading`** (spinner +
  audio qui joue).

**Fix** : appeler `player.pause()` sans condition (libvlc met en pause même si `canPause` est
faux) + dans `handleStateChange`, re-pauser quand `!wantsPlay` pour que moteur et contrôleur ne
divergent pas.

### 3. Échec partiel Xtream écrase silencieusement le bon cache — ✅ corrigé (22/11 : les listes/catégories en échec reprennent le catalogue précédent, test `failedXtreamEndpointKeepsThePreviousList`)

`Sources/PrismData/Repositories/CatalogRepository.swift:166-169, 204-212, 92-98`

- `try? client.categories` → des kinds entiers perdent leurs catégories → tous leurs items
  disparaissent des étagères de catégories.
- Si 1–2 des 3 endpoints de listes échouent, le catalogue partiel est construit **et persisté par
  `cache.save` par-dessus le cache précédent** → films/séries disparaissent de l'UI *et* du
  disque jusqu'à un refresh entièrement réussi. Aucune erreur n'est remontée pour les échecs
  partiels.

**Fix** : ne pas persister un catalogue partiel (skip `cache.save` si `failures` non vide, ou
fusionner les kinds en échec depuis le catalogue précédent) ; remonter les échecs partiels dans
`ImportProgress`/`errors`.

## Bugs élevés

| # | Bug | Endroit |
|---|-----|---------|
| 4 | ✅ corrigé — **Trap `Int` sur ≥19 chiffres** dans `NameWork.parseX` (contrairement à `parseSE` qui borne les digits) — `99999999999999999999x12` dans un nom M3U/Xtream crashe | `PrismCore/Normalization/TitleNormalizer.swift:770,775` |
| 5 | ✅ corrigé — **Trap `Int` dans `LenientValue.year`** — run de chiffres non borné atteignable via tous les décoders Xtream sur payload hostile | `PrismCore/Support/LenientJSON.swift:140` |
| 6 | ✅ corrigé — **Trap `Int` dans `LenientValue.hms`** — `reduce(0){$0*60+$1}` overflow sur grosses composantes (`duration`) | `PrismCore/Support/LenientJSON.swift:194` |
| 7 | **Live : `fallbackURLs` jamais essayées après le premier frame** — `advanceAttempt` n'est accessible qu'avant le premier rendu ; un flux mourant en cours de route reteste la même URL morte 5× (~15 s) puis `.failed`, alors que `LivePlayback.makeItem` construit soigneusement la liste de fallback | `PrismPlayer/Controller/PlayerController.swift:354-389` |
| 8 | **Pause pendant le chargement grille le plan d'essai** → chaque tentative timeout 10 s → plan épuisé → `.failed` pour un simple pause (pire sur plans VLC-only `.ts`) | `PrismPlayer/Controller/PlayerController.swift:348-370` |
| 9 | **Reconnect planifié jamais annulé** si le flux récupère pendant le backoff (stall résolu, `.time` reprend) → teardown d'un stream sain, flash noir, saut à live edge en timeshift | `PrismPlayer/Controller/PlayerController.swift:372-389` |
| 10 | ✅ corrigé (`URLSession.data` + progression KVO) — **Download M3U octet par octet** — `for try await byte in bytes` = ~100M itérations async pour 100 MB → des dizaines de secondes d'overhead sur chaque import remote (chemin dominant) | `PrismData/Repositories/CatalogRepository.swift:240` |
| 11 | ✅ corrigé (22/11 : `EPGGuide.merged` fusionne toutes les sources en une passe, index des noms construit une fois, hors acteur) — **`EPGGuide.merging` reconstruit `nameIndex` sur l'acteur** — ~4 `TitleNormalizer.normalize` par chaîne × ~20k chaînes = secondes de CPU synchrone ; `cachedGuide` fait S−1 merges au bootstrap, `currentGuide` re-merge après chaque refresh/remove ; bloque `refresh`, `shortEPG`, `lastFetched` | `PrismData/EPG/EPGGuide.swift:117-137` ; `EPGRepository.swift:46,53` |
| 12 | ✅ corrigé (22/11 : `resolveEPGID` mémoïsé, classification mémoïsée par texte + préfiltre octets) — **`sportsSchedule` : ~2M classifications** — `resolveEPGID` (normalize lourd par miss) + `classify` (2 folds/programme) × ~10k chaînes × ~200 programmes ≈ 20–60 s CPU par appel, réévalué à chaque rebuild tant que la page sports est ouverte | `PrismData/EPG/SportsBroadcast.swift:45-71,107-131` |
| 13 | **VLC `.stopped` → `.ended` inconditionnel** — un stop milieu de flux (perte réseau/demux) est traité comme fin naturelle → `currentTime = duration` + `onEnded` → `library.markWatched` à tort sur VOD | `PrismPlayer/Engine/VLCEngine.swift:380-381` ; `PlayerController.swift:500-512` |
| 14 | **VLC timeshift : timebase non vérifié** — `seekableRange` = `0…length` mais `player.time` possiblement absolu → `timeshiftWindow`, `playbackFraction`, `isBehindLiveEdge`, `clampedSeekTarget` faux (knob pinné, seeks clampés faux). **À vérifier sur device** avec une vraie source timeshift | `PrismPlayer/Engine/VLCEngine.swift:181-185,397-425` |
| 15 | **VLC ne transmet que `User-Agent`/`Referer`** — `Cookie`, `Authorization` et autres headers de `PlaybackItem.httpHeaders` silencieusement perdus (libvlc 3.x n'a pas d'option générique ; mapper au moins `cookie` → `:http-cookie=`) | `PrismPlayer/Engine/VLCEngine.swift:85-91` |

## Bugs moyens

### PrismUI

- ✅ corrigé — **`.recentlyAdded` affiche tout le catalogue** — `case .all(let kind), .recentlyAdded(let kind)` retourne
  `catalog.movies`/`series` complet ; la page "Ajouts récents" est identique à "Tous les films/séries".
  `catalog.recentlyAdded(kind, limit:)` existe mais n'est pas utilisée ici.
  `PrismUI/Browse/Collections.swift:73-74` — *vérifié dans le code actuel.*
- ✅ corrigé (le carrousel `BrowseHero` possède son index) — **`BrowseScreen` recalcule tous les rayons à chaque avancée du hero** (toutes les 12 s ou au tap sur
  un dot) : `selectedHero` en `@State` → reevaluation du body → `hero()` scanne des centaines de
  candidats, `continueWatching` ≤3000 entrées, etc. Isoler le hero dans un enfant dédié ou laisser
  `HeroCarousel` posséder son index.
  `PrismUI/Browse/BrowseScreen.swift:11,45-53`
- ✅ obsolète (Discovery remplacé par le moteur de sélection `Curator`) — **`Discovery` fetch annulé quand la page se désactive** : `request` devient nil → `.task(id:)`
  cancel le fetch TMDB en vol ; au retour, refetch. `PrismUI/Browse/BrowseScreen.swift:35,103-105`
- **DatePicker du guide sans label d'accessibilité** (`labelsHidden` + pas d'`accessibilityLabel`).
  `PrismUI/Screens/Live/LiveGuide.swift:67-73`
- **Player live sous target `.title`** : `PrismPlaybackWindow` n'affiche les contrôles live
  (canal panel, zapping, programme) que si `controller.isLive && target == .channel` — latent
  aujourd'hui, fragile pour un futur appel `.title`+live. `PrismPlaybackSession.swift:129-158`
- **Collections non bornées** : `.all`/catégorie retournent des tableaux potentiellement 100k+ dans
  un `LazyVGrid` — viable mais profondeur de scroll et coût `ForEach` croissent linéairement.

### PrismData

- **`reconcileMediaIdentities` perd les alias éditoriaux** quand un groupe est scindé par tmdbID —
  `titleIndex` n'indexe que `media.aliases` → `catalog.title(aliasID)` → nil → watchlist/historique/
  variantes préférées cassés après rebuild. `CatalogBuilder.swift:482-489` vs `:373-375`
- ✅ corrigé (22/11 : snapshot sur main, encodage + écriture détachés, générations ordonnées) — **`LibraryStore.saveNow` sur le main actor** — `snapshot()` (tri ≤3000 progress + watched + prefs)
  + encode JSON + `data.write(.atomic)` toutes les ~1,5 s après mutations → stalls ~10–50 ms pendant
  la lecture. `Stores/LibraryStore.swift:361-383`. Fix : snapshot sur main, encode+write en
  `Task.detached`/acteur utilitaire avec génération.
- **Refresh EPG en vol ressuscite après `forget`** — `AppModel.remove` ne garde que `imports[id]`
  (imports catalogue), pas les refreshs EPG : un refresh qui complète après `forget` réécrit
  `guides[id]`/`fetchedAt[id]` + cache → guide orphelin en mémoire et sur disque. Pure fuite.
  `EPGRepository.swift:73-113` ; `AppModel.swift:362-379`
- ✅ atténué (22/11 : `memmem` vectorisé au lieu de la boucle octet par octet) — **`SearchIndex.substringSearch`** : chaque token fallback alloue une map `wordCount` et fait du
  `containsBytes` naïf sur tous les mots uniques — ~300–500k mots × ~4 tokens ≈ 1–2M scans
  (~50–200 ms CPU) par frappe qui rate la recherche préfixe. `SearchIndex.swift:463-509`
- ✅ obsolète (l'UI n'utilise plus `DiscoveryBuilder.local`; le `Curator` part d'un index construit une fois par catalogue) — **`DiscoveryBuilder.local` rescanne tout le catalogue** à chaque changement de `DiscoveryProfile`
  (mutations watchlist/historique) — O(titres × variants) ≈ 1–5 s `@concurrent`.
  `Catalog/Discovery.swift:55-70`
- ✅ corrigé (22/11 : mémo par groupe de chaînes, partagé par les copies du guide) — **`EPGGuide.resolveEPGID` non mémoïsé sur MainActor** — channels sans epgID explicite →
  `TitleNormalizer.normalize(name)` (~50–200 µs) par appel, par nom, invoqué par ligne de guide et
  par tuile de chaîne pendant l'évaluation des vues. `EPGGuide.swift:102-114,147-151` ;
  call sites `LiveGuide.swift:133`, `LiveScreen.swift:278`
- **`Catalog.related` fold les genres par candidat sur MainActor** — `list.prefix(5_000)` × folds,
  dizaines de ms par appel, recalculé à chaque render de la page related. `Catalog.swift:214-255`
- **`SegmentedArchive.unpack` copie chaque segment** (`data.subdata`) → ~2× mémoire transitoire sur
  archives de centaines de MB. `Stores/SegmentedArchive.swift:47` — utiliser des slices.
- **`EPGCache.load` fait confiance à `meta.programCount`** pour `reserveCapacity` avant validation —
  meta corrompue → allocation déraisonnable. `Stores/CatalogCache.swift:185`
- **I/O disque synchrone sur acteurs** — `Data(contentsOf:)` + JSON + write atomique dans des
  fonctions `nonisolated` appelées depuis des méthodes isolées → bloque l'acteur ~1–50 ms.
  `DetailRepository.swift:141-155`, `MetadataRepository.swift:207-243`
- **`EPGRepository.refresh` fetch les URLs EPG séquentiellement** — jusqu'à 3 URLs × 120 s timeout
  → pire cas des minutes par refresh. `EPGRepository.swift:89-104`
- ✅ corrigé (22/11 : fusion linéaire de deux listes triées) — **`EPGGuide.merging` re-trie des listes déjà triées** — concatène puis `sort` O(n log n) par
  channel id en conflit ; un merge O(n) suffit. `EPGGuide.swift:124`

### PrismCore

- **`LenientValue.day` classe les dates compactes comme timestamps Unix** — run de chiffres
  `> 100_000` → `Date(timeIntervalSince1970:)` : `yyyymmdd` → août 1970, `yyyymmddHHMMSS` → année
  ~650 000. Formats plausibles pour `releasedate` et `get_short_epg`. `LenientJSON.swift:117-120`
- **`Gzip.isCompressed` rate le zlib** — seul `1F 8B` détecté alors que `decompress` supporte zlib
  (`32 + MAX_WBITS`) → `invalidData` pour EPGs compressés zlib. `Gzip.swift:7-9` ;
  `XMLTVParser.swift:42`
- **`finishPrograms` O(n²) par chaîne** — scan de `sorted[(k+1)...]` pour chaque programme ;
  un two-pointer sur les starts distincts suffit (et `nextStart` n'est utile que pour
  `missingStop`). `XMLTVParser.swift:365`
- **Attributs `user-agent`/`referer` EXTINF droppés si ≤4 attributs** — `if attributes.count > 4`
  arbitraire : un `#EXTINF` avec `tvg-id` + `user-agent` seulement ne transmet jamais son UA.
  `M3UParser.swift:211`
- **Markdown `**` incomplet** — `dropFirst(2)` ne strip que le préfixe quand le label commence par
  `**` ; `Mot de passe: **secret**` garde les astérisques → mauvais mot de passe → échec auth sur
  des pastes markdown courants. `XtreamCredentials.swift:117-118`
- **`parseSE` rejette les épisodes avec lettres collées** — `S01E02VOSTFR`, `S01E02MULTI` non
  reconnus → séries françaises mal classées. `TitleNormalizer.swift:762`
- **`CatchupURL.expand` : spécificateurs `{…}` inconnus → replay nil** — `{Ymd}`, `{yyyy-mm-dd}`…
  désactivent le catch-up silencieusement. `CatchupURL.swift:74`
- **Divers** : port Xtream droppé si `url` a déjà un scheme (`XtreamDecoder.swift:48`) ;
  `bitrate` Kbps vs `video.bit_rate`/1000 → 1000× gonflé si panel en bps (`:409`) ;
  `backdrop_path`/`still_path` relatifs TMDB droppés (`:136,206,264`) ; `normalizeServer` strip
  `/c/` qui peut être légitime (`XtreamCredentials.swift:31-40`) ; label `login` absent du
  provider-message parser (`:180`) ; `EPGProgram.id` collision même-start (`EPG.swift:4`) ;
  `<subtitle>` sans tiret ignoré (`XMLTVParser.swift:213`) ; 408 non retryable + `Retry-After`
  HTTP-date ignoré (`HTTPClient.swift:73,88`) ; showKey `key+"|"+group` duplique les séries
  listées sous plusieurs groupes (`M3UCatalogMapper.swift:303`)

### PrismPlayer (suite)

- **`play()` depuis `.ended` race le seek async** — `engine.play()` avant que `seek(to: 0)`
  n'atterrisse → `didPlayToEndTime` ré-émis → `.ended` + `onEnded` doublé. `PlayerController.swift:629-636`
- **VLC stall-détect possible faux positif** — si l'horloge libvlc n'avance pas sur certains
  formats live, `lastProgressAt` ne se rafraîchit jamais → reconnect d'un stream sain en boucle.
  `VLCEngine.swift:399-412` ; `PlayerController.swift:514-537` — *à vérifier sur device*
- **`contentAspectRatio` jamais relâché + `videoSize` jamais reset** entre items → lock de ratio
  persistant après une lecture avec préférence. `PlayerWindowConfigurator.swift:100-107` ;
  `PlayerController.swift:223-238`
- **Taper la source/le canal courant recharge le stream** — `Toggle(isOn:)` ignore la nouvelle
  valeur → `action()` → teardown complet du même flux. `PlayerMenus.swift:211-215` ;
  `PrismPlaybackSession.swift:195-205`
- **VLC `trackSignature` = "audio/sub counts"** — un swap de pistes à counts égaux n'émet jamais
  `.tracksChanged` → menu stale ; les pistes `isForced` ne sont pas filtrées (contrairement à AVF).
  `VLCEngine.swift:264-278,439-444`
- **`subtitleStyle` mort sur VLC** — propagé mais jamais appliqué ; le menu Style ment.
  `VLCEngine.swift:179` ; `PlayerMenus.swift:116-124`
- **`handleEnded` sans dedup** — un second `.ended` re-tire `onEnded` → `markWatched` doublé
  (idempotent aujourd'hui). `PlayerController.swift:500-512`
- **VOD `.failed` mid-playback change de moteur définitivement** — une erreur réseau transitoire
  sur AVF laisse le titre sur VLC jusqu'à la fin ; pas de reconnect same-attempt comme le live.
  `PlayerController.swift:364-366`
- **AirPlay inerte pour VLC** — `AVRoutePickerView.player = nil` mais le bouton s'affiche.
  `EngineVideoView.swift:58-101`
- **`stop()` laisse l'état stale** — `duration`/`currentTime`/tracks/`videoSize`/`techInfo`
  survivent au prochain `start()`. `PlayerController.swift:241-250`
- **Divers** : up-next sans countdown ni auto-avance (`PrismPlaybackSession.swift:181`) ;
  `onContinuousHover` → `noteUserActivity()` non throttlé (~120 Hz) ; `supportsTimeshift` /
  `preferredEngine` champs morts jamais renseignés ; sous-titres auto-pick `subtitleTracks.first`
  arbitraire (`PlayerMenus.swift:60-63`) ; headers HLS→segments AVF à vérifier sur device
  (`AVFoundationEngine.swift:88-99`) ; `buffered == current` pour VLC VOD (cosmétique).

### PrismDesign

- **`encodedData` bufferise toute la réponse avant validation** — une URL image Xtream
  malveillante vers un fichier de plusieurs centaines de MB (ou stream infini dans le timeout
  60 s) spike la mémoire ; rien n'est disk-caché si `isDecodable` échoue → chaque retry
  re-télécharge. `Images/ImagePipeline.swift:262-277`. Fix : `session.bytes(for:)` ou
  `expectedContentLength`/MIME avant le body.
- **`PosterWallGrid.==` ignore `spacing`** — changement de spacing sur un `PosterWall` vivant ne
  re-render pas. `Onboarding/PosterWall.swift:129-132`
- **`HeroScrollGesture` axis stickiness** avale un scroll vertical dans les 0,2 s après un swipe
  horizontal (events non phasés : molette). `Hero/HeroHorizontalScroll.swift:88-120`
- **`HeroBackdrop` : Ken Burns 1.025 vs spec 1.06** ; init multi-URL `animates: false` par défaut
  → hero de détail statique (spec : Ken Burns) ; `leadingScrim` defaults incohérents (0.75 vs
  0.72). `Hero/HeroBackdrop.swift:25-61,86`
- **Dérive des tokens vs spec AGENTS.md** (~10 écarts) : `shelfTitle` 17 vs 19, `rankNumber` 48 vs
  64 heavy, `episodeEyebrow` 11 vs 10 semibold caps, `badgeHeight` 12/padding 3.5 vs 14/4,
  `primaryButtonHeight` 36 vs 40 (commentaire dit mesuré device — trancher), LabelPill
  font/forme/fond différents de la spec. `Tokens/`, `Badges/LabelPill.swift`
- **`ChipBar.scrollClipDisabled()`** peut peindre des chips hors limites — ChipBar inutilisé
  aujourd'hui, latent. `Controls/ChipBar.swift:48`
- **`TitleLogo` ignore Reduce Motion** pour son cross-fade (`withAnimation` inconditionnel).
  `Hero/TitleLogo.swift:40`
- **`PosterWall` division par zéro** si `spacing <= -tileWidth` (init public sans validation).
  `Onboarding/PosterWall.swift:71-83`
- **`BadgeSpec.id = text`** : doublons de badges → IDs `ForEach` dupliqués. `Badges/MediaBadge.swift:62`
- **`AgeRatingBadge`** : label "Déconseillé aux moins de X" absurde pour `TP`/`E`/`Tous publics`.
  `Badges/AgeRatingBadge.swift:25`
- **`ExpandableText`** : action accessibilité "Afficher plus" même non tronqué.
  `Text/ExpandableText.swift:78-80`
- **`HeroCarousel` montre des contrôles morts** quand `isInteractive == false` (masqué par
  `opacity(0)` aujourd'hui). `Hero/HeroCarousel.swift:136-158`
- **`SourceCard` `strokeBorder(lineWidth: 0)`** — vérifier si SwiftUI rend un hairline sur les
  cartes non sélectionnées. `Cards/SourceCard.swift:52`
- **Dead code** : `isEmptyMenu` (CardSupport.swift:165), `NoiseTexture`
  (PlaceholderArtwork.swift:115), `cachedAverageColor` (ImagePipeline.swift:167),
  `hoverLift` public (HoverLift.swift:6), `CompressedCodableFile` (PrismData, superseded par
  `SegmentedArchive`), `order`/`episodeCounter` (M3UCatalogMapper.swift:199,331)
- **`ShelfMenuHeader`** : hint "Choisir une saison" hardcodé sur header générique.
  `Shelves/ShelfHeader.swift:106`
- **`PlaceholderArtwork`** : sélection de style sur titre non trimé. `Images/PlaceholderArtwork.swift:23-27`

## Optimisations

| Impact | Quoi | Où |
|--------|------|-----|
| Fort | `SearchIndex.substringSearch` : trigram index ou skip fallback sur gros index / tokens courts | `SearchIndex.swift:463-509` |
| Fort | `EPGGuide.resolveEPGID` : mémoïser par `ChannelGroup.id` (ou cache normalize) — sort du MainActor | `EPGGuide.swift:102-114` |
| Fort | `DiscoveryBuilder.local` : pré-calculer les preuves audio par titre une fois par catalogue | `Discovery.swift:55-70` |
| Fort | `Catalog.related` : genres foldés pré-calculés au build (ou appel en `.task`/cache) | `Catalog.swift:214-255` |
| Fort | `CatalogRepository.download` : `session.data(for:)` ou lecture par blocs + progression via `Content-Length` | `CatalogRepository.swift:240` |
| Moyen | `EPGGuide.merging` : merge O(n) de deux runs triés au lieu de re-sort ; `nameIndex` paresseux ou incrémental | `EPGGuide.swift:117-137` |
| Moyen | `sportsSchedule` : tag sport stocké sur `EPGProgram` au build du guide, ou cache par `program.id` ; pré-filtrer les chaînes | `SportsBroadcast.swift` |
| Moyen | `EPGRepository.refresh` : fetch des URLs EPG en concurrence (merge par priorité) | `EPGRepository.swift:89-104` |
| Moyen | `LibraryStore.saveNow` : encode+write hors main actor | `LibraryStore.swift:361-383` |
| Moyen | `SegmentedArchive.unpack` : slices au lieu de `subdata` | `SegmentedArchive.swift:47` |
| Moyen | I/O disque `@concurrent`/utility actor dans `DetailRepository`/`MetadataRepository` | divers |
| Faible | `Gzip.decompress` : cap de sortie (EPG hostile → GBs) + réserve 512 MB trop large | `Gzip.swift:24` |
| Faible | `TMDBClient.cache` non borné → LRU/`NSCache` ; `MetadataRepository.episodeMemory` ignore la TTL | `TMDBClient.swift:144` ; `MetadataRepository.swift:114-129` |
| Faible | `BrowseScreen` : isoler `selectedHero` du body des rayons | `BrowseScreen.swift` |
| Faible | `M3UParser.parseAttributes` : corriger la boucle (cf. critique #1) | `M3UParser.swift:265` |
| Faible | `PosterWall` : re-raster périodique ~60-80 MeshGradient à chaque `rowShift` (~20 s) — hitch GPU possible sur machines faibles | `Onboarding/PosterWall.swift:87-151` |
| Faible | `hoverLiftEffect` : shadow layer permanente même invisible — gate sur `isHovered` | `Controls/HoverLift.swift:13` |
| Faible | `topIndices` repose sur un ordre d'index non documenté — compare `(score, index)` ou documente le prérequis | `CatalogBuilder.swift:864-883` |
| Info | ✅ atténué (22/11 : URL stockées en texte via `@CompactURL`, valeurs répétées partagées — −220 Mo sur 300k items) — Mémoire : chaque item catalogue stocké 2× (`SourceCatalog` + `MediaVariant` dans `Catalog`) + index de recherche — ~2× items à 100k+ ; envisager des variantes par ID si la mémoire pose problème | structurel |

## Points forts vérifiés (ne pas casser)

- **Zéro force unwrap / `try!` / `as!`** sur données externes dans tout le code.
- **Concurrence Swift 6 propre** : actors pour repositories/caches, `Sendable` value types,
  `@concurrent` sur le parsing lourd, annulation disciplinée (`onTermination`, `Task.checkCancellation`),
  aucun retain cycle (player teardown exemplaire : KVO/notifications/time observer tous invalidés,
  refs engine→contrôleur en `weak`).
- **Pipeline d'images exemplaire** : decode keys bucketées, fetches encodées partagées,
  dédup en vol avec annulation par waiters, NSCache bytes + disque LRU SHA-256, downsampling
  ImageIO sans upscale, `RemoteImage` quantifié 8 px + `.task(id:)` pour annuler hors écran.
- **Persistance** : écritures `.atomic` partout, `SegmentedArchive` header/version/count validés,
  `CatalogCache.decode` vérifie les comptes.
- **Réseau** : timeouts par requête (8–120 s), retries bornés backoff + `Retry-After`, XXE off,
  SportsClient bloque les redirects et pin `*.thesportsdb.com` (SSRF-safe), credentials Xtream dans
  l'URL sans fuite dans les erreurs, `permitsSharedHeaders` empêche les credentials cross-host.
- **SearchIndex** : chemin préfixe = binary search + driver smallest-posting + dedupe bitmap +
  ranking par tiers — sain.
- **Regroupement catalogue** : dédup par sourceID first-wins, ordre des sources = priorité,
  normalisation parallèle, indices O(1), annulation entre phases.
- **EPG timeshift** : `XMLTVParser` ajoute `timeShiftHours` à chaque timestamp ;
  `EPGRepository.shortEPG` applique le même shift — cohérent.
- **Player** : gardes de génération anti-events stale, teardown current+retiring, transitions
  last-frame au zap, state machine auto-hide correcte (deadline prolongé pendant sleep),
  triple-état `MediaTrack.ID??` correctement déballé.
- **Accessibilité** : labels sur tous les contrôles icône-seuls, images décoratives cachées,
  Reduce Motion respecté partout, conteneurs lazy pour les grandes listes.

## Plan de correction suggéré

1. `M3UParser.parseAttributes` — boucle infinie (1 ligne)
2. `VLCEngine.pause()` — pause live cassée + wedge `.loading`
3. `CatalogRepository` — ne pas persister un catalogue partiel + surfacer les échecs
4. Les 3 traps `Int` (`parseX`, `LenientValue.year`, `LenientValue.hms`) — violation directe de
   la règle « no crash on dirty data »
5. `CatalogRepository.download` — lecture par blocs
6. Fallbacks live après premier frame (PlayerController `advanceAttempt` en reconnect)
7. `EPGGuide.merging`/`resolveEPGID` — coût acteur + MainActor à 20k chaînes
8. `.recentlyAdded` → `catalog.recentlyAdded(kind, limit:)`
9. `LibraryStore.saveNow` hors main actor
10. `reconcileMediaIdentities` — préserver les alias sur split tmdbID
