# Audit performance, stutters & bugs — 2ᵉ passe

> Réalisé le 2026-11-22 par **10 agents d'exploration en parallèle**, un par périmètre :
> PrismCore (parsing / réseau), PrismData (catalog+search / stores+EPG), PrismDesign
> (images / cards+shelves+hero), PrismUI (shell+home / live+search+detail / onboarding),
> PrismPlayer (complet). Chaque finding a été tracé jusqu'à ses appelants.
>
> Complète `AUDIT.md` (1ʳᵉ passe, bugs) : ce document se concentre sur **perf, stutters,
> mémoire et justesse à l'échelle 100k+ items**. Les findings déjà documentés dans
> `AUDIT.md` sont renvoyés en §H au lieu d'être dupliqués.
>
> **Méthode** : audit statique read-only. Les points marqués « à mesurer » nécessitent
> Instruments (view updates, hitches, pic mémoire) pour quantification.

## Synthèse par module

| Module | Verdict |
|---|---|
| PrismCore parsing | Soigné (memchr, `@concurrent`) — mais XMLTV préfixé ignoré, gzip sans cap, `pending` M3U non purgé |
| PrismCore réseau | Acteurs propres, cancellation exemplaire — mais auth-erreur → succès vide, décodage sérialisé, pic mémoire JSON |
| PrismData catalog/search | Vraie index inversée, lookups O(1) — mais Curator re-scanne tout, groupement séquentiel, pic 2× au rebuild |
| PrismData stores/repos | SegmentedArchive/versioning propres — mais décodage parallèle non borné, caches non plafonnés, refresh EPG sans dédup |
| PrismDesign images | Pipeline exemplaire (downsample, dédup, LRU) — mais **aucun cache négatif** et **prefetch jamais câblé** |
| PrismDesign cards/hero | Lazy partout, ombres au hover only, RM respecté — mais `scrollPosition` par frame + churn hover |
| PrismUI shell/home | Observation fine dans l'ensemble — mais `curatedFeeds` global, **pages jamais démontées**, calculs O(n) dans body |
| PrismUI live/detail | Listes lazy, index EPG binaire — mais menus de tuiles eager, bugs UX mineurs |
| PrismUI onboarding | Import pipeline solide — mais PosterWall ~58 Mo GPU re-rasterisé, pas de retour onboarding après dernière source |
| PrismPlayer | Zéro fuite, teardown exemplaire — mais VLC temps non throttlé, seek non confirmé, HLS live sous-bufferé |

---

## A. Bugs fonctionnels

### A1 — Critique : réponses auth-erreur Xtream = succès vide → cache écrasé

`PrismCore/Xtream/XtreamDecoder.swift:345-353` (`elements`), `PrismData/Repositories/CatalogRepository.swift:168-176, 222-225`

Quand le panel renvoie `{"user_info": {...}}` (auth KO, maintenance) sur `get_live_streams`/`get_vod_streams`/`get_series`/`get_*_categories`, `elements(_:)` retourne `[]` silencieusement. Ces listes vides sont traitées comme des **succès** : `fetchedCategories.live == nil` est faux (c'est `[]`, pas `nil`), `failedCategoryKinds` reste vide, `merge(kinds:from:)` ne restaure rien → le catalogue vide est persisté via `cache.save` **par-dessus le bon cache disque**, qui survit aux relances.

> À vérifier par rapport au fix du bug #3 de `AUDIT.md` (échecs partiels) : celui-ci couvrait les endpoints en échec, pas le cas « succès vide ».

**Fix** : lever `XtreamError.unauthorized` quand `user_info` est présent avec `auth == 0`, au lieu de retourner `[]`.

### A2 — Majeur : XMLTV préfixé (`<tv:programme>`) ignoré silencieusement → guide vide

`PrismCore/Parsing/XMLTVParser.swift:47-49, 195-269`

`shouldProcessNamespaces = false` → `elementName` conserve le préfixe (`tv:programme`) → aucune comparaison ne matche. `parser.parse()` renvoie `true` sur XML bien formé → **document vide sans erreur**. Fréquent chez les providers XMLTV.

**Fix** : activer `shouldProcessNamespaces` et comparer le nom local, ou stripper le préfixe (`elementName.split(separator: ":").last`).

### A3 — Majeur : suppression de la dernière source → pas de retour onboarding

`PrismUI/App/AppModel.swift:155, 298-306, 414-431`

`bootstrap()` décide onboarding vs ready via `sources.isEmpty`, pas via `hasCompletedOnboarding` (write-only). `remove(_:)` ne touche jamais `phase` ; `restartOnboarding()` n'a **aucun appelant**. Supprimer la dernière source laisse l'app sur un catalogue vide en session, puis onboarding au prochain lancement — incohérent.

**Fix** : `if sources.isEmpty { restartOnboarding() }` dans `remove(_:)` ; utiliser ou supprimer le flag.

### A4 — Majeur : `pending` EXTINF non purgé sur ligne URL invalide

`PrismCore/Parsing/M3UParser.swift:195-199` vs `:225`

`urlLine` retourne tôt si `hasAllowedScheme`/`makeURL` échoue **sans effacer `pending`** → une ligne parasite entre `#EXTINF` et la vraie URL transfère nom/durée/attributs à l'entrée suivante. Corruption silencieuse fréquente sur playlists malformées.

**Fix** : `pending = nil` (et décider du sort de `pendingHeaders`) sur toute ligne de contenu qui n'aboutit pas.

### A5 — Mineur : page « Reprendre » affiche « 0 titres »

`PrismUI/Browse/Collections.swift:243` (`case .continueWatching: []`), `:99-105, 169-171, 193-195`

`items` retourne `[]` → `header(count: 0)` → « 0 titres » permanent, alors que la vraie liste est rendue par la branche dédiée.

**Fix** : passer `nil`/le vrai compte à `header` pour `.continueWatching`.

### A6 — Mineur : sélecteur de jour du guide atterrit sur 00:00–04:00

`PrismUI/Screens/Live/LiveGuide.swift:67-70, 339-349`

`set: { start = Calendar.current.startOfDay(for: $0) }` + fenêtre max `slotCount ≤ 8` × 30 min = **4 h** → choisir une date fixe montre minuit→4 h, pas « maintenant ». L'utilisateur doit cliquer « Maintenant ».

**Fix** : pour la date du jour, caler `start` sur la tranche contenant `now`.

### A7 — Mineur : recherche — spinner à chaque frappe (pas de stale-while-revalidate)

`PrismUI/Browse/SearchScreen.swift:50, 61-67`

`resultRequest == request` exige l'égalité complète (terme + révision + indexReady + actif) → chaque caractère change `request.term` → `ProgressView` pendant ≥150 ms + recherche. `LiveScreen` conserve les résultats précédents (`hasSameScope`, `LiveScreen.swift:64-69`) — bon pattern à répliquer.

**Fix** : afficher `result` pendant la frappe ; spinner seulement si `result == nil`.

### A8 — Mineur : `app.update` silencieusement ignoré pendant un import → modifs perdues

`PrismUI/App/AppModel.swift:372` + `Shell/SourceSettings.swift:264-272`

`guard imports[source.id] == nil else { return }` → « Enregistrer » sur `EditSourceSheet` retourne sans effet puis `dismiss()` → saisie perdue sans avertissement.

**Fix** : retourner `Bool`/`throw`, ou désactiver « Enregistrer » via `app.isImporting(source.id)` + message.

### A9 — Mineur : numérotation épisodes erronée quand `episode_num` manque

`PrismCore/Xtream/XtreamDecoder.swift:248-252`

`for (index, item) in raw.enumerated()` — index global **toutes saisons confondues** → fallback `episode_num ?? (index+1)` donne à un épisode S2 sans `episode_num` le numéro 11+ au lieu de 1.

**Fix** : compteur par saison (`var nextNumber: [Int: Int]`).

### A10 — Mineur : bugs de parsing de dates/valeurs sales

- `PrismCore/Support/LenientJSON.swift:113-130` : `LenientValue.day` jj/mm/aaaa sans validation heure (`hh<24, mm<60, ss<61`) ; « 12/25/2019 » (US) → nil ou mauvaise date ; tout nombre nu = epoch → « 2023 » → 1970.
- `LenientJSON.swift:202-215` : `base64Text` accepte tout titre plein texte qui est aussi base64 valide → mojibake (« U0VSSUVT » → charabia). Utilisé par `shortEPG`.
- `PrismCore/Xtream/XtreamDecoder.swift:43-52` : `serverURL(_:)` peut produire `host:port:port` ; `normalizeServer` droppe userinfo silencieusement (`XtreamCredentials.swift:17-50`).
- `PrismCore/Xtream/XtreamURLBuilder.swift:67-75, 98-100` : fallback `url(string, fallback: c.server)` → le player tente de lire la racine au lieu d'erreur claire ; `container_extension` absent → `"mp4"` par défaut → 404 sur MKV.
- `PrismCore/Parsing/M3UParser.swift:211-218` : seuil `attributes.count > 4` → un `#EXTINF` avec seulement `user-agent` perd l'en-tête (déjà noté `AUDIT.md`, confirmé présent).

### A11 — Mineur : `LiveGuide.airingProgramme()` utilise `Date.now` au lieu de l'horloge tickée

`PrismUI/Screens/Live/LiveGuide.swift:136-138` vs `:26` (`LiveClock` fournit `now` à la grille)

La ligne rouge et les blocs utilisent `timeline.now` (30 s) mais `airingProgramme()` — pour `onPlay`/contextMenu de chaque ligne — appelle `guide.nowAndNext(at: Date.now)` → titre lu pour lecture ≠ titre affiché près des frontières (jusqu'à ~30 s d'écart).

**Fix** : passer `timeline.now` à `airingProgramme`.

### A12 — Mineur : divers data/demo

- `PrismData/Demo/DemoContent.swift:52` : `guideBlocks[channel.categoryID ?? ""]` utilise l'id complet (`prism-demo:live:info`) alors que les clés sont `"info"`/`"sport"`/`"demo"` → fallback systématique, sport/démo sans leurs programmes.
- `PrismPlayer/Engine/VLCEngine.swift:181-182` : `subtitleStyle` stocké mais jamais appliqué (commentaire dit « next load » mais `load()` ne le lit pas) — `setSubtitleStyle` no-op côté VLC.
- `PrismPlayer/Engine/AVFoundationEngine.swift:204-219, 378-380` : sous-titres « Non » → si le groupe interdit la sélection vide, retombe sur piste forcée que `subtitleTracks` ne liste pas → désync UI/moteur.
- `PrismPlayer/PlaybackItem.swift:42` + `LivePlayback.swift:26-30` : `supportsTimeshift` jamais renseigné → `minimumWindow` toujours 60 s → seek ±10 s jamais activé (code mort, déjà noté `AUDIT.md`).
- `PrismData/Curation/CurationIndex.swift:261-264` : `isLanguageTag` accepte tout tag 2-7 chars hors liste noire → codecs (`X264`, `AAC`, `DTS`, `TRUEHD`, `ATMOS`…) gonflent `languages.count` → scores reach/popularity/façades biaisés.
- `PrismData/Repositories/SeriesCastRepository.swift:33-57` : pas de dédup en vol ni persistance → 2 appels concurrents = 2× `/search/shows` + `/shows/:id/cast`.
- `PrismData/Repositories/CatalogRepository.swift:320-346` + `ImportProgress.swift:57-65` : `validate`/`SourceValidation` sans appelant (code mort) ; `AppModel.moveSources` (`:433-440`) sans appelant.
- `PrismData/Stores/CompressedCodableFile.swift` : fichier entier sans appelant (superseded par `SegmentedArchive`).
- `PrismData/Repositories/EPGRepository.swift:62-65` : `lastFetched` décode tout le cache EPG pour lire une `Date` — piège latent.
- `PrismUI/App/AppModel.swift:336,358` : `errors[id]` = `localizedDescription` brut → anglais technique possible dans l'UI française (`displayError` d'`AddSourceView` non réutilisé).
- `PrismData/Networking` (hors scope mais vu) : `SportsClient.swift:15` clé démo `"123"` en dur — vérifier si voulu ; `HTTPClient.swift:59-63` `Retry-After` plafonné à 5 s (un `Retry-After: 30` ignoré → re-429) ; `XtreamClient.swift:34,84-88` `adultIDs` peut refetcher catégories en double sur panel flaky.

---

## B. Performance & stutters

### B1 — Critique : pages et sections jamais démontées → invalidations multipliées + mémoire

`PrismUI/Shell/PageStack.swift:30-38`, `Shell/LibraryShell.swift:13,17-20,29-41,62-64`

Toutes les pages de la pile restent dans un `ZStack` à `opacity(0)` ; chaque section visitée garde un `PageStack` complet monté (`visited` ne rétrécit jamais). Conséquences :

- **Observation** : chaque page masquée continue de souscrire à `AppModel`/`LibraryStore` — un tick de progression, un refresh catalogue ou un changement de feed ré-évalue le body de **toutes les pages de toutes les sections visitées** (un `TitleDetailView` enterré recalcule `heroEpisode` et les tuiles d'épisodes toutes les 5 s pendant la lecture).
- **Mémoire** : `RemoteImage.onDisappear { loaded = nil }` ne se déclenche pas à opacité 0 → les `CGImage` décodées persistent ; profondeur de pile illimitée (`NavigationModel.push`, `App/Navigation.swift:69-74`).
- **Coût** : pendant l'animation push/pop 0,35 s, toute la pile est compositée.

**Fix** : plafonner les pages conservées par pile (garder les 3-5 dernières), éviction LRU des sections non récentes, ou `.hidden()` + démontage pour les pages profondes. *(trouvé par 2 agents)*

### B2 — Critique : `continueWatching`/`latestProgress`/`snapshot()` en O(gros) sur MainActor toutes les ~5 s

`PrismData/Stores/LibraryStore.swift:303-363` (`continueWatching`), `:174-176` (`latestProgress`), `:422-434` (`snapshot`), appelés depuis `BrowseScreen.swift:118`, `Collections.swift:114`, `TitleDetailView.swift:104-109, 522-535`

- `continueWatching` : itère jusqu'à 3 000 entrées progress → `catalog.titleID(containing:)` + `catalog.title()` par entrée → `locateEpisode` (scan variants × saisons × épisodes) + `nextUnwatchedEpisode` (**re-trie toutes les saisons/épisodes à chaque appel**) par série + `items.contains` O(n) → O(n²) worst-case + tri. Le `limit` (14/80) ne réduit pas le coût d'entrée.
- `latestProgress` : scan de tout `progress` par appel, par carte.
- `snapshot()` : trie `progress.values` + `watched.sorted()` (**jamais borné**) + prefs — sur MainActor ~1,5 s après chaque mutation.

Tout est invoqué **dans `body`** → `app.library` est `@Observable` → chaque checkpoint de progression (toutes les ~5 s pendant la lecture, `PlayerController.onProgress` throttle `PlaybackPolicies.swift:113-127`) ré-évalue toutes les vues qui l'ont lu — y compris les pages masquées (cf. B1). Pics de plusieurs dizaines de ms main-thread, proportionnels à la bibliothèque.

**Fix** : mémoïser le résultat (invalidé sur génération progress + `catalogRevision` + historique), ou `.task` + `@concurrent` (pattern déjà utilisé par `CollectionView.collect`, `Collections.swift:248`) ; court terme sauter le calcul si `isPageActive == false` ; plafonner `watched` (~20k) ; construire `LibraryFile` dans le `Task.detached` ; throttle persistance à 15-30 s. *(trouvé par 3 agents — finding le plus convergent)*

### B3 — Majeur : `Shelf.scrollPosition` en `@State` → invalidation par frame de scroll

`PrismDesign/Shelves/Shelf.swift:31, 103-111`

`.scrollPosition($position)` est réécrit par le ScrollView **à chaque changement de position** (~chaque frame) → `@State` invalide `Shelf.body` → tout le sous-arbre (header + `LazyHStack` + `card(item)` de toutes les cartes matérialisées, `RemoteImage` lookups, placeholders, textes) ré-évalué en continu. Le code a déjà résolu ce problème pour les bords (`viewport.edges` en classe + `Equatable`) mais pas pour `position`.

**Fix** : `.scrollPosition(id:anchor:)` (binding `Item.ID?` — `Item: Identifiable` le permet) qui ne notifie qu'au changement d'ancre, ou `ScrollPosition` piloté uniquement au clic de chevron. *À mesurer avec Instruments (view updates) — impact certain mais ampleur à quantifier.*

### B4 — Majeur : `curatedFeeds` — une propriété pour 3 scopes → invalidation croisée

`PrismUI/App/AppModel.swift:69, 197-217` ; lu par `BrowseScreen.swift:23,45`, `SearchScreen.swift:45`

`private var curatedFeeds: [CurationScope: CuratedResult]` non `@ObservationIgnored` → toute écriture (recomposition d'un feed `.home`) invalide les `BrowseScreen` Films et Séries **montées en permanence** via `visited`. Multiplié par B1.

**Fix** : boîtes `@Observable` par scope, ou table `[CurationScope: Int]` de révisions que chaque vue lit.

### B5 — Majeur : Curator — ~25-45 scans complets du ranking par shelf, ×3 scopes, à chaque recomposition

`PrismData/Curation/Curator.swift:430-464` (`candidates`), appelé par `take`, `titles(for:)`, `rotatingPlatforms` (9 facettes), `rotatingDecades`, `genreTiles`, `composeHighlights`

Chaque appel itère `index.ranking(kind)` en entier pour les facettes hors `followsGeneralScore`. Une composition = ~25-45 scans × O(éligibles) ; ×3 scopes × chaque `catalogRevision`/`curationRevision`/profil/langues/jour (`AppModel.refreshFeed:206-217`). Des centaines de ms CPU à chaque recomposition — heureusement `@concurrent`, mais la fréquence est le problème (cf. B4 + `recordPlayback` → nouveau `CurationRequest` complet).

**Fix** : mémoïser les listes de candidats par (kind, facet) dans `FeedBuilder` ou pré-calculer dans `CurationIndex` ; débouncer les recompositions (~2-5 s) ou exclure `watched` récent du hash du request.

### B6 — Majeur : hover par carte pendant le scroll — rafale de ré-évaluations

`PrismDesign/Cards/CardSupport.swift:131-167`, `Controls/HoverLift.swift:10-18`

Chaque carte a `@State hovering` + `.onHover`. Pendant un scroll (horizontal et vertical), des dizaines de cartes entrent/sortent du hover/seconde : chacune ré-évalue son `body` (RemoteImages → lookups + allocs, placeholders → hash FNV, accessibilityText joins), anime un spring scale et alloue/libère un calque `.shadow(radius: 18)`. Une traversée verticale fait basculer ~15 cartes d'un coup dans la même transaction. S'aggrave avec B3.

**Fix** : propager un flag « scrolling » (`BrowseScrollActivity.isScrolling` existe déjà, `BrowseScreen.swift:61-63,137-140`) en `@Entry` environment et suspendre lift/ombre dans `CardContainer`/`ArtworkSurface` — l'affordance n'a pas de sens en inertie.

### B7 — Majeur : `DetailEpisodeTile` — 2 downloads + 2 décodages par épisode

`PrismUI/Detail/DetailEpisodeTile.swift:37-44` ; mécanisme `Images/RemoteImage.swift:72-76,165-171`, `ImagePipeline.swift:241-245`

Chaque tuile monte **deux** `RemoteImage` pour le même still : fond `blurRadius: 24` + image principale. Le flou n'a pas `blurSourceSize` (`blursArtwork(sized:)` est `internal` et non utilisé ici, contrairement à `ExtendedArtwork` `CardSupport.swift:67-68`) → `ArtworkURL.resolve` choisit une taille différente → **2 requêtes HTTP + 2 décodages par tuile**. Sur 30-100 épisodes visibles par batch, le trafic et les slots `ImageDecodeQueue` (6) doublent.

**Fix** : rendre `blursArtwork(sized:)` public et l'appeler avec la taille de l'image principale.

### B8 — Majeur : menu contextuel des tuiles chaînes évalué à chaque rendu

`PrismUI/Screens/Live/LiveScreen.swift:283` → `PrismDesign/Cards/ChannelTile.swift:36` (`self.menu = menu()` évalue le `@ViewBuilder` à l'init) → `channelMenu` `:286-310`

Par tuile visible, à chaque tick `LiveClock` (30 s) et chaque changement catalogue/bibliothèque : `library.isFavorite(group.id)` = `favoriteChannels.contains` O(#favoris) (`LibraryStore.swift:148`) + arbre `Menu` « Choisir la source » complet (`ForEach(group.variants)` + `LivePlayback.preferredVariant`). La grille `LazyVGrid` limite au visible (~60-100) mais le menu est évalué même jamais ouvert — contrairement au guide qui évalue `airingProgramme()` à l'ouverture (`LiveGuide.swift:142`).

**Fix** : closure paresseuse (`() -> MenuContent`) ou `.contextMenu` direct sur la tuile ; sortir `isFavorite` du chemin chaud (Set ou révision). Aussi `Filter.favorites: [String]?` dans l'id de tâche hashe le tableau complet par éval (`LiveScreen.swift:35-47`) → stocker une révision favoris.

### B9 — Majeur : groupement/dédup catalogue séquentiel mono-thread

`PrismData/Catalog/CatalogBuilder.swift:269-312` (`groupMedia`), `686-779` (`groupChannels`), `443-501` (`reconcileMediaIdentities`)

Clés, construction des titres et tri sont parallélisés, mais la passe de groupement (lookup resolveur + insertions `datedGroups`/`undatedGroups`/`groupIndex` par item) est **strictement séquentielle** — probablement le plus gros coût mono-cœur du build à 100k+ items (des centaines de ms). `mediaGroups.reserveCapacity(total)` (`:262`) sur-alloue aussi.

**Fix** : sharder le groupement par hash de clé puis fusionner dans l'ordre déterministe ; paralléliser `reconcileMediaIdentities` par chunks.

### B10 — Majeur : Curator/`CurationIndex` — catalogue sans artwork → pages curées vides

`PrismData/Curation/CurationIndex.swift:205-211` (`isEligible` exige `posterURL || backdropURL` + `year || rating`), `233-242`, `Curator.swift:134`, `Recommendations.swift:148`

Un provider M3U sans posters (cas fréquent) produit `movieRanking`/`seriesRanking` vides → `Curator.feed` = `.empty` → Home/Films/Séries **sans aucun shelf** (seules catégories et recherche restent).

**Fix** : mode dégradé — shelves avec placeholders monogramme quand aucune œuvre du kind n'a d'artwork, ou assouplir l'éligibilité si `ranking` est vide.

### B11 — Majeur : `TitleNormalizer.normalize` par item, sans mémoïsation

`PrismCore/Normalization/TitleNormalizer.swift:38` ; appelé à `M3UCatalogMapper.swift:16` (chaque entrée M3U), `XtreamDecoder.swift:85,125,164,381` (chaque élément JSON), `EPGGuide.swift:169,229`, `CatalogBuilder` (rejoué à chaque chargement de cache via `TitleRefinement.refine`, `CatalogCache.swift:104,111`)

~5-15 µs par titre (preprocess + tokenisation + ~6 passes) → 1-3 s CPU pour 100k+ items ; les doublons de `rawName` (même titre en plusieurs qualités — fréquent) recalculés à l'identique.

**Fix** : cache `[String: NormalizedName]` par import ; pour le cache disque, ne re-affiner que `needsWork`.

### B12 — Majeur : `ProviderSynopsis.cleaned` par variante, sans cache

`PrismCore/Support/ProviderSynopsis.swift:25-52` ; appelé par variante à `CatalogBuilder.swift:573,612`

Contrairement à `cleanGenres` (mémoïsé), chaque plot est retraité : `needsNormalization` O(n) + `NSRegularExpression` + jusqu'à 12 `NLLanguageRecognizer.processString` par paragraphe → des dizaines de secondes possibles sur 100k items.

**Fix** : mémoïser par chaîne de plot ou pré-filtrer avant fragments/reconnaisseur.

### B13 — Majeur : double matérialisation M3U + dictionnaire d'attributs par entrée

`PrismCore/Parsing/M3UParser.swift:11,16` (`attributes`/`headers` `[String:String]` par `M3UEntry`), `M3UCatalogMapper.swift:15`, `CatalogRepository.swift:276-283`

`parsePlaylist` construit d'abord tout le `M3UPlaylist` puis tout le `SourceCatalog` → pic ≈ 2× (facilement plusieurs centaines de Mo à 100k+ entrées). Chaque `#EXTINF` alloue un dictionnaire (~8 paires).

**Fix** : streamer les entrées vers le mapper ou compacter les attributs (clés internées / tableau plat).

### B14 — Mineur : travail string/formatage dans les `body` de cartes — à hisser à l'init

Amplifié par B3/B6 (× carte × ré-évaluation) :

- `Cards/EpisodeCard.swift:88,131-137` — `eyebrow.uppercased()` + `accessibilityText` (joins) par éval
- `Cards/PosterCard.swift:49,90` ; `Cards/WideCard.swift:122-128` ; `Cards/ChannelTile.swift:61,98-104` ; `Cards/RankedPosterCard.swift:39,53` ; `Cards/SourceCard.swift:25,66`
- `Images/PlaceholderArtwork.swift:51,102-110` — `Palette(seed:)` refait FNV-1a + ~10 RNG **à chaque body eval** de chaque placeholder visible (le plus coûteux)
- `Badges/MediaBadge.swift:21-22,27,71-72` — `Set<String>` de 10 éléments alloué par init + `uppercased()` par eval
- `Text/MetadataLine.swift:25,54`, `Text/AboutCard.swift:24` — `joined`/`uppercased` par eval

**Fix** : calculer dans `init` ou propriétés stockées ; `Set` de `MediaBadge` en `static let`.

### B15 — Mineur : `RemoteImage.body` — allocation `NSString` avec URL complète par lookup

`Images/RemoteImage.swift:88-96`, `ImagePipeline.swift:53,481`

Chaque `body` construit la `Key` puis `MemoryCache.image(for:)` alloue un `NSString` avec le `cacheKey` texte (URL entière, 100-300 car.). `Key` est déjà `Hashable`.

**Fix** : `MemoryCache` par `Key` dans `Dictionary` + lock, ou mémoïser `cacheKey` dans `Key` (calculée une fois dans `key()`).

### B16 — Mineur : `HeroCarousel` allocations/scans par éval ; `ChipBar` glass par chip

- `Hero/HeroCarousel.swift:43-46` (`currentIndex` = `firstIndex` O(n) ~3×/body), `:93` (`onChange(of: items.map(\.id))` alloue un tableau d'IDs par body eval). Timer `Task.sleep` OK.
- `Controls/ChipBar.swift:35-50,81-96` : chaque chip = vraie `glassEffect` + `@State isHovered` + `withAnimation` + `matchedGeometryEffect` — acceptable à ~13 chips, pas à l'échelle ; `withAnimation` sur sélection ignore Reduce Motion (léger écart).
- `PrismUI/Screens/Sports/SportsHomeShelf.swift:98,106` : ~16 glass effects non fusionnés sur Home (2 par carte × 8) sans `GlassEffectContainer`.
- `Shelves/Shelf.swift:107-110,124-137` : chevrons pop-in/out sans animation aux bords de scroll (`scrollAvailability` change hors transaction).

### B17 — Mineur : divers scans et allocations

- `PrismUI/Shell/SourceSettings.swift:75,101-104` : `SourceDetailView.counts(for:)` = 3 `reduce` O(100k+) par page source montée × `catalogRevision` → calculer une fois dans `AppModel` (index par sourceID) ou mémoïser.
- `PrismData/Catalog/Catalog.swift:139-151` : `titles(in:)`/`channels(in:)` matérialisent `[MediaTitle]`/`[ChannelGroup]` complets (jusqu'à 50k+) à chaque appel depuis `CollectionView`/`LiveScreen` → accesseur indexé ou vue lazy sur les `Int32` de `groupMembers`.
- `PrismData/Catalog/Catalog.swift:91-102` : `providerLanguages` interpole `"\(sourceID):\(kind):"` + concatène à chaque appel dans des boucles chaudes → cache `[ContentID: Set<String>]`.
- `PrismData/Curation/Curator.swift:711-717` + `Catalog/Recommendations.swift:47-64,177-186` : `availableAudio`/`localizedName` bouclent sur **tous** les variants (alors que le reste borne à prefix 6/16/48) — ~500×/compose.
- `PrismUI/Browse/Collections.swift:151,155-163,290-322` : genreChips/`arrange` O(100k) par ouverture de collection `.all` (`@concurrent` + cancellation OK — acceptable, à surveiller) ; `arrange(.title)` re-normalise chaque titre → mémoïser les clés.
- `PrismData/EPG/SportsBroadcast.swift:111-118` : `classify` concatène `title+subtitle+categories` pour chaque programme avant lookup mémoïsé → ~300k allocations par build de gros guide → mémoïser sur hash/tuple sans concaténation.
- `PrismData/EPG/EPGGuide.swift` + `PrismCore/Models/Identifiers.swift:39-42` : `ContentID.parts` re-split `rawValue` à chaque accès `sourceID`/`kind`/`nativeID` (allocation en boucle) ; `EPGProgram.id` réinterpole une String par accès.
- `PrismData/Stores/LibraryStore.swift:44,103-119,436-446` : `watchlist.contains` O(n) par `isInWatchlist` (par carte) ; `apply` ne plafonne pas `progress`/`watchlist`/`favoriteChannels` depuis `library.json`.
- `PrismUI/App/AppModel.swift:516-529` : `imports[id]` réécrit à chaque tranche 512 Ko → ~200 écritures/invalidation sidebar par import de 100 Mo → n'écrire que si fraction arrondie ou throttle 4-10 Hz.
- `PrismUI/App/AppModel.swift:289-294, 362-368` : `refreshAll`/bootstrap = N imports parallèles non bornés (N sources périmées → N auth Xtream + 3 listes + EPG) → sémaphore 2-3.
- `PrismUI/App/AppModel.swift:479-490` : `isRefreshingGuide` bool non fiable sous appels concurrents (defer d'un appel remet false pendant qu'un autre tourne → spinner intermittent) ; `refreshGuide` sans dédup → voir D4.

---

## C. Mémoire

### C1 — Critique : décodage de caches parallèle non borné → pic multi-GB au lancement

`PrismData/Stores/CatalogCache.swift:94-122` (`decode`), `:205-212` (`EPGCache.load`), `Repositories/CatalogRepository.swift:26-36` (`cachedCatalogs`), `EPGRepository.swift:27-48` (`cachedGuide`)

`withTaskGroup` **sans limite** : tous les segments d'un catalogue (~17 segments pour 100k films, chunkSize 6 000) et tous les catalogues/EPG de toutes les sources décodés simultanément (LZFSE + JSONDecoder par segment). Pic = somme des JSON décompressés + tableaux décodés de toutes les sources en vol → plusieurs Go transitoires, risque jetsam sur multi-sources 100k+ ou XMLTV énorme.

**Fix** : borner la concurrence (sémaphore / lots de ~4 segments) ; paralléliser par source mais séquentiellement par segment.

### C2 — Critique : pic mémoire import Xtream 3-5× la réponse JSON

`PrismCore/Xtream/XtreamDecoder.swift:333-352`, `Support/LenientJSON.swift:7-11`, `XtreamClient.swift:41,50,56`

`get_vod_streams`/`get_series`/`get_live_streams` ne paginent pas (limitation API) — une réponse = 50-200 Mo. `session.data` bufferise tout, `JSONSerialization.jsonObject` matérialise l'arbre `Any` complet, `elements` retourne `[Any]` conservé pendant le mapping, `Data` source et modèles coexistent. `Data(trimmed)` (`:337`) recopie probablement le buffer. Pic estimé 0,5-1 Go sur 100k items.

**Fix** : libérer `data` avant la boucle de mapping, éviter `Data(trimmed)`, envisager parse par tranches ; court terme documenter le plafond.

### C3 — Majeur : décodage des gros catalogues sérialisé sur l'acteur `XtreamClient`

`PrismCore/Xtream/XtreamClient.swift:42-57, 72-80, 118-155` ; `XtreamDecoder.*` (toutes `static`)

Avec `NonisolatedNonsendingByDefault`, les `XtreamDecoder` synchrones héritent l'isolation de l'appelant → `JSONSerialization` + `TitleNormalizer` par item s'exécutent **sur l'acteur**. Dans `refreshXtream`, les 3 téléchargements partent en parallèle mais les 3 décodages se sérialisent → import = max(réseau) + Σ(décodages) au lieu de max(réseau, décodage).

**Fix** : `@concurrent` sur les points d'entrée du décodeur ou `Task.detached` dans `liveStreams`/`vodStreams`/`series` + `Task.checkCancellation()` avant décodage.

### C4 — Majeur : `ImagePipeline.encodedData` bufferise toute la réponse

`PrismDesign/Images/ImagePipeline.swift:317-331`

`session.data(from:)` charge l'intégralité du body avant `isDecodable`/`disk.store`. URL image hostile/stream lent → pic mémoire ; échec → rien sur disque → re-téléchargement (amplifie D1). Déjà noté `AUDIT.md` — confirmé présent.

**Fix** : `session.bytes(for:)` avec cap ~30-50 Mo ou rejet sur `expectedContentLength`/Content-Type ; persister les bytes même si indécodables.

### C5 — Majeur : caches non bornés (détail, métadonnées, TMDB, bibliothèque, disque)

- `PrismData/Repositories/DetailRepository.swift:12-15, 84-87, 137-155` : `movies`/`series` sans plafond (`SeriesDetail` inclut saisons+épisodes) ; un fichier JSON par `ContentID` dans `Details/` jamais supprimé (TTL 3 j vérifié à la lecture seulement) ; `clearMemory()` sans appelant. IO fichier synchrone sur l'acteur.
- `PrismData/Repositories/MetadataRepository.swift:18-22, 79-83, 207-243` : `memory`/`episodeMemory`/`trendMemory` sans plafond ; `readDisk`/`writeDisk` synchrones sur l'acteur ; fichiers `Metadata/` sans purge.
- `PrismCore/TMDB/TMDBClient.swift:144, 202` : `cache` `[String: TMDBMetadata]` non borné (~10-100 Ko/entrée → dizaines de Mo en longue session).
- `PrismData/Stores/LibraryStore.swift:44,184,196,416-419,436-446` : `watched` jamais purgé, `apply` ne plafonne rien.
- `PrismDesign/Images/ImageDiskCache.swift:19,56-58,71` : `touched: Set<String>` croît toute la session (~8-10 Mo à 100k images).
- `PrismData/Catalog/CatalogBuilder.swift:175-199, 257-265, 322-397` + `Catalog.swift:39-55` + `SearchIndex.swift:35-55` : pic ≈ 2× empreinte catalogue au rebuild (ancien catalogue + index + nouveau simultanément, `AppModel.publish` libère après coup `AppModel.swift:583-605`) ; `keys` = 1 String par item brut.

**Fix** : plafonds LRU (~200 détails, ~500 métadonnées, ~128 TMDB comme `SeriesCastRepository`), purge `Details/`/`Metadata/` au-delà TTL au démarrage, `Set`+tableau pour watchlist, cap `touched`, mesurer le pic rebuild sous Instruments.

### C6 — Majeur : `PosterWall` méga-texture ~58 Mo GPU re-rasterisée périodiquement

`PrismDesign/Onboarding/PosterWall.swift:76-107, 134-151` ; `Onboarding/OnboardingView.swift:18-19`

Grille ~11×11 ≈ 120 cellules (MeshGradient 3×3 + gradients + Text) rasterisée en **une texture** `.drawingGroup()` : 1440×900 @2× sur-échantillonné ≈ 4576×3183 px ≈ **~58 Mo GPU**. `rowShift` change toutes les `pitchY/speed` ≈ **29 s** → re-raster complet des 120 MeshGradients → micro-saccade GPU périodique sur le premier écran. `paused` ignore occlusion fenêtre et `isPageActive` (alors que `WindowOcclusionReader`/`appearsActive` existent).

**Fix** : réduire le sur-échantillonnage (`coverWidth*1.25`→`*1.05`), rasteriser par colonne, baisser `rasterizationScale` ; check d'occlusion comme `HeroCarousel`. Déjà noté `AUDIT.md` (optimisations Faible) — ampleur précisée ici.

### C7 — Majeur : décompression gzip sans limite de sortie

`PrismCore/Support/Gzip.swift:24, 34-64`

`reserveCapacity(min(data.count * 8, 512 << 20))` + boucle `inflate` sans plafond → EPG gzip hostile/corrompu (bombe) → OOM/jetsam ; la réserve peut allouer 512 Mo d'un coup pour un gzip de ~64 Mo. Déjà noté `AUDIT.md` (Faible) — confirmé.

**Fix** : caper la sortie (~1-2 Go → throw) et réduire la réserve (`min(count*4, 256 Mo)`).

### C8 — Mineur : `EPGCache`/`CatalogCache` pas d'éviction ni de quota disque

`PrismData/Support/AppDirectories.swift:58-64` (`Details/`, `Metadata/` croissent sans borne), `CatalogCache.swift:12`/`EPGCache.swift:160` (bump `formatVersion` → anciens fichiers ignorés mais restent sur disque), `EPGCache.swift:239-241`/`CatalogCache.swift:55-57` (remove uniquement via `forget`).

**Fix** : passe de nettoyage opportuniste au démarrage (TTL / formats obsolètes).

---

## D. Images — pipeline

### D1 — Majeur : aucun cache négatif → URLs mortes re-téléchargées à chaque apparition

`PrismDesign/Images/ImagePipeline.swift:117-137, 234-266, 317-331` ; `RemoteImage.swift:127-132`

Un échec (404, timeout, HTML, `isDecodable` faux) ne laisse **aucune trace** : pas d'entrée mémoire, rien sur disque, `inFlight`/`dataInFlight` purgés au `release`. Les `LazyHStack`/`LazyVGrid` détruisent l'état des cartes hors écran → chaque retour de scroll relance `.task(id:)` → `cachedImage` miss → nouvelle requête. Sur un catalogue IPTV où une grande fraction des `tvg-logo`/backdrops sont morts (cas courant), défiler puis revenir = **tempête de requêtes** vers des hôtes morts (jusqu'à 20 s timeout par host qui pend).

**Fix** : `failedURLs: [URL: Date]` borné dans `ImagePipeline` (TTL session) consulté dans `image(for:)`/`sharedData`, ou sentinel disque ; côté `RemoteImage`, `@State failed` pour ne plus retenter dans la vue.

### D2 — Majeur : toute l'infra de prefetch est morte — rien ne pré-charge les étagères

`PrismDesign/Images/ImagePipeline.swift:159-180, 333-412` ; `Shelves/Shelf.swift:85-122`

`warm()`, `prefetch(_:)`, `cancelPrefetch()`, `warmQueue` (3 connexions host, priorité background) : **zéro appelant** dans l'app (vérifié par grep — seuls `PrismTools` et `BrowseScreen.swift:172-180` preload manuel de l'unique slide hero suivante). Chaque carte ne télécharge qu'au montage `LazyHStack` → pop-in visible en scroll rapide ; `httpMaximumConnectionsPerHost = 6` (`ImagePipeline.swift:92`) sature vite sur un host Xtream unique. **C'est le principal écart avec « scroll smooth sur 100k+ items ».**

**Fix** : `ImagePipeline.shared.warm(prochainsItems, pixelSize:)` à l'apparition d'un shelf (N items suivants le viewport), cancel à la disparition — l'API existe déjà avec file bornée (600), dédup `dataInFlight`, warm queue dédiée.

### D3 — Mineur : bugs dans l'infra prefetch (latent tant que D2 non câblé)

- `ImagePipeline.swift:392-412` : `prefetchFinished(url)` fait `prefetches[url] = nil` sans vérifier l'identité → un task annulé peut effacer l'entrée d'un prefetch plus récent → task orpheline. Fix : comparer `ObjectIdentifier` (pattern déjà utilisé par `warmFinished:371-375`).
- `ImagePipeline.swift:392-400` : dédup prefetch par URL seulement, ignorant taille/fitting → la variante `.fit`/`.fill` suivante n'est jamais pré-chargée. Fix : indexer par `Key`.

### D4 — Mineur : `averageColor` déclenche un second download + décodage par URL

`ImagePipeline.swift:188-195` ; `Cards/CategoryTile.swift:67-72`

`averageRGBA` → `image(for: maxPixelSize: 64)` → `.fit` → `ArtworkURL.resolve` choisit `w342` pour TMDB ≠ `w500/w780` de la carte → entrée disque + téléchargement + décodage dédiés par tuile de genre. Mémoïsé ensuite (`averageColors`, cap 4000 avec `removeAll` brutal `:193`).

**Fix** : échantillonner depuis le CGImage déjà décodé par la carte.

### D5 — Mineur : divers pipeline

- `Hero/TitleLogo.swift:36-42` : `withAnimation` inconditionnel (ignore Reduce Motion) ; `logo` pas reset au changement d'URL ; `.task` hop acteur même sur hit mémoire.
- `ImagePipeline.swift:198-200` (`cachedAverageColor`), `PlaceholderArtwork.swift:115-131` (`NoiseTexture`), `warm`/`prefetch`/`purgeMemory` (app) : dead code.
- Cycle de rétention transitoire pendant loads (`Task.detached` capture acteur → `inFlight` → task → self) : borné par timeout 60 s, auto-cicatrisant.

### D6 — Info : écart spec (pas un coût perf)

`ChannelTile.swift:49-58` : fond gris uni `Color(white: 0.36)` — la spec prévoit « logo centered on a colour-sampled gradient ». `averageColor` existe (`ImageDecoder.swift:104`, `@concurrent`) mais n'est appelé que par `CategoryTile`. Aucun sampling couleur sur main thread — la crainte de stutter est écartée.

---

## E. Player

### E1 — Majeur : événements `.time` VLC non bridés → invalidations + appels libvlc à haute fréquence

`PrismPlayer/Engine/VLCEngine.swift:400-434` (émission `:415`), `:482-484` ; `Controller/PlayerController.swift:431-465`

Chaque notification `mediaPlayerTimeChanged` → `EngineEvent.time` **sans throttle** (vs 250 ms côté AVF, `AVFoundationEngine.swift:323`). VLCKit peut émettre à cadence variable, jusqu'à ~image/image sur VFR/MKV (cas typique VOD IPTV). Chaque tick mute `currentTime`/`bufferedTime` (invalidation scrubber + `PlayerUpNextHost`) et, pour le live, appelle `engine.seekableRange` → `player.isSeekable` + `player.media?.length` (`VLCEngine.swift:184-188`) — 2 appels libvlc sur main thread par événement. Bonus : `buffered` vaut toujours `current` → `bufferedFraction` inutile pour VLC.

**Fix** : `player.timeChangeUpdateInterval = 0.25` dans `VLCEngine.init`/`load` et/ou n'émettre `.time` que si `now - lastEmit >= 0.25 s` ; `seekableRange` en cache ~1 Hz.

### E2 — Majeur : seek VLC « fire-and-forget » → scrubber revient en arrière

`PrismPlayer/Engine/VLCEngine.swift:120-123` ; `Controller/PlayerController.swift:652-665, 433`

`player.time = VLCTime(...)` est asynchrone libvlc : `seek(to:)` retourne immédiatement, `seekTask` passe à nil, `handleTime` ré-accepte les temps moteur — qui restent l'ancienne position tant que le seek n'a pas abouti. Le scrubber saute à la cible puis « rubber-bande » vers l'arrière pendant ~0,5-2 s sur VOD réseau (cas MKV/TS = majorité du VOD IPTV). AVF `await player.seek` retient `seekTask` — pas de problème.

**Fix** : conserver `seekTask` jusqu'à ce que `currentTime` moteur soit à ±1 s de la cible (ou timeout ~3 s), ou événement « seek finished » par le moteur VLC.

### E3 — Majeur : live HLS via AVFoundation — buffer avant 3 s + pas d'évitement de stall

`PrismPlayer/Engine/AVFoundationEngine.swift:101-103`

`preferredForwardBufferDuration = 3` pour le live + `automaticallyWaitsToMinimizeStalling = false`. Les segments HLS live font typiquement 4-10 s : 3 s de buffer < 1 segment → underrun à chaque pic de débit → image figée (le moteur rapporte `.buffering`, `handleLikelyToKeepUp` ne reprend qu'au keep-up `:470-474`). Chemin `m3u8` → `.avFoundation` (`EngineSelector.swift:21,54`).

**Fix** : buffer live 15-30 s et/ou réactiver `automaticallyWaitsToMinimizeStalling` pour le live — à valider sur flux IPTV réels. **Cause probable des stalls live.**

### E4 — Majeur : seek VOD AVF en tolérance exacte `.zero`

`PrismPlayer/Engine/AVFoundationEngine.swift:123`

Chaque seek VOD MP4/MOV décode depuis le keyframe précédent (GOP IPTV fréquents 5-10 s) → attente visible ~0,3-1 s, image figée, sans indicateur. Chemin commun du VOD.

**Fix** : `toleranceBefore/After` ≈ 1-2 s pour le VOD (précision perçue sous la seconde), ou seek rapide puis seek fin à l'arrivée.

### E5 — Majeur : `isPictureInPictureActive` non réinitialisé lors d'un zap/remplacement

`PrismPlayer/Controller/PlayerController.swift:311-323` (`beginAttempt` ne reset pas), `:427,568` (reset seulement dans `tearDownEngines`)

AVF + PiP actif → `replace(with:)` (zap, épisode suivant, autre source) → le nouvel engine n'émet jamais `.pictureInPicture(false)` → flag reste `true` → overlay « Lecture en Image dans l'image » (`PlayerView.swift:177-187`) permanent sur la nouvelle vidéo.

**Fix** : `isPictureInPictureActive = false` dans `beginAttempt` (ou à `.firstFrame`).

### E6 — Mineur : maintien des flèches ←/→ = tempête de seeks

`PrismPlayer/UI/PlayerView.swift:496-501` ; `Controller/PlayerController.swift:652-665`

Les flèches ne filtrent pas `isRepeat` (contrairement à espace/F/M/S/L et zap ↑/↓). Chaque repeat → `skip(±10)` → nouveau `Task` + `engine.seek` ; `seekTask?.cancel()` n'annule pas l'`await player.seek` sous-jacent → seeks empilés dans AVPlayer → position qui « court » + micro-saccades + spam HUD `.skip`.

**Fix** : sauter uniquement sur `.down` et laisser un repeat gérer un seek continu, ou throttler (~200 ms).

### E7 — Mineur : lectures de propriétés VLC sur main thread en continu

`VLCEngine.swift:184-188` (`seekableRange`), `:236-242` (`audioTracks`/`subtitleTracks` → `audioTrackNames`/`Indexes`, `videoSubTitlesNames`/`Indexes`), `:448-453` (`refreshTracksIfNeeded` lit les index à chaque poll 1 s), `:307-333` (`techInfo` → `tracksInformation` + `statistics`, 1×/s tant que la carte `I` est ouverte, `PlayerOverlays.swift:168-173`)

Chaque accès traverse VLCKit → libvlc (verrous internes) sur MainActor. Cumulé avec E1 → gigue.

**Fix** : cacher pistes/débit dans le moteur, n'actualiser qu'au `.tracksChanged` ou basse fréquence.

### E8 — Mineur : divers player

- `PlayerController.swift:223-238` + `PlayerWindowConfigurator.swift:100-107` : `videoSize` jamais reset + `contentAspectRatio` jamais relâché entre items → l'ancienne résolution persiste après zap/épisode (déjà noté `AUDIT.md`, confirmé).
- `PrismUI/App/PrismPlaybackSession.swift:181` + `PlayerOverlays.swift:203-206` : `PlayerUpNextCard` `remaining: 0, countdown: 0` codé en dur → anneau toujours plein (déjà noté `AUDIT.md`).
- Scrubber : monté seulement contrôles visibles (`PlayerView.swift:192-199`) → ticks 4 Hz n'invalident qu'un sous-arbre minime — bien.
- Points forts : pas de fuite (KVO/notifications/time observers tous invalidés `AVFoundationEngine.swift:519-553`), moteurs recréés par tentative avec generation guard, sélecteur de pistes sans recréer le player, `stop()` VLC hors main (`VLCEngine.swift:125-140`), auto-hide auto-corrigé, aucun `try!`/`as!`/force unwrap.

---

## F. Réseau & data — chantiers secondaires

- **EPG refresh sans déduplication** — `PrismUI/App/AppModel.swift:479-490` + `EPGRepository.swift:78-118`, déclenché par `LiveScreen.swift:322-326` et `SportsScreen.swift:198-206` (boucle sur toutes les sources, sans garde ni annulation du précédent). Deux appels concurrents pour la même source retéléchargent/re-parsent tout l'XMLTV (jusqu'à ~120 s, dizaines de Mo) puis ré-encodent le cache ; `guide = await currentGuide` re-merge tout après *chaque* source. **Fix** : `guideImports: [SourceID: Task]` (pattern `inFlight` déjà dans `MetadataRepository`/`SportsRepository`).
- **EPG multi-URLs séquentielles** — `EPGRepository.swift:94-109` : jusqu'à 3 URLs (`prefix(3)`) en `for` séquentiel, timeout 120 s / resource 600 s chacune → pire cas ~30 min. **Fix** : `withTaskGroup` + merge. (Déjà noté `AUDIT.md` — confirmé.)
- **`TitleNormalizer`/`ProviderSynopsis` non mémoïsés** — voir B11/B12.
- **`Gzip.isCompressed` rate le zlib** — `Gzip.swift:7-9` : seul `1F 8B` détecté alors que `decompress` supporte zlib → `invalidData` pour EPGs zlib (déjà noté `AUDIT.md`).
- **`finishPrograms` O(n²) worst-case par chaîne** — `XMLTVParser.swift:361-368` : scan avant dans la liste triée pour chaque programme sans `stop` → two-pointer ou recherche binaire (déjà noté `AUDIT.md`).
- **`SegmentedArchive.unpack` copie chaque segment** — `Stores/SegmentedArchive.swift:47` : `data.subdata` → ~2× mémoire transitoire sur archives de centaines de MB → slices (déjà noté `AUDIT.md`).
- **I/O disque synchrone sur acteurs** — `DetailRepository.swift:141-155`, `MetadataRepository.swift:207-243` : `Data(contentsOf:)` + JSON + write atomique dans `nonisolated` appelé depuis méthodes isolées → bloque l'acteur ~1-50 ms (déjà noté `AUDIT.md`).
- **`EPGGuide` index déjà bon** — index par chaîne, listes triées, recherche binaire, dédup `resolveEPGID` via `ResolutionMemo`, merge O(n) — les requêtes guide ne sont **pas** des scans linéaires (point fort).
- **`SportsClient`** : session éphémère dédiée, refuse redirects (`NoSportsRedirects`), valide hosts d'images (`:101-109`) — bon garde-fou SSRF ; clé démo `"123"` en dur à vérifier.
- **`TransferObserver.invalidate()` sauté si `session.data` throw** — `CatalogRepository.swift:250-254` : fuite bornée (meurt avec l'objet) mais progrès faux sur retry/redirect.
- **Keychain synchrone sur MainActor + erreurs avalées** — `CredentialStore.swift:72-107` via `AppModel.swift:151,325,375,420,444,448,457,461` : `SecItemCopyMatching`/`Update`/`Delete` bloquants (<1 ms typiquement, peuvent caler) ; tout statut ≠ `errSecSuccess` → `nil` indistinguable d'une absence (`errSecInteractionNotAllowed` → `missingCredentials` fantôme) ; chaque `tmdbKey`/`secret(named:)` refait une lecture (`MetadataRepository.currentClient():172` par `metadata(for:)`). **Fix** : logger statuts, mémoïser les secrets côté dépôts.
- **`LibraryStore` init/flush sur MainActor** — `LibraryStore.swift:87-93` (decode `library.json` ~3000 progress dans `init` depuis `AppModel.init`) ; `flush()` → `writeNow` → encode synchrone au quit (commentaire `:406` admet 10-50 ms). Encode+write des mutations débouncées déjà déportés (`Task.detached:413`) — bien.
- **`CatalogRepository.readLocalPlaylist`** : `@concurrent` + `Data(contentsOf:options:[.mappedIfSafe])` — un M3U de 50 Mo jamais lu sur main — bien.
- **HTTPClient** : `PrismURLSession.shared` correct (`urlCache=nil`, cookies off, `httpMaximumConnectionsPerHost=6`, resource timeout 600 s) ; `waitsForConnectivity=false` + `.notConnectedToInternet` non retryable — pas de retry storm hors-ligne ; 408 non retryable + `Retry-After` HTTP-date ignoré (déjà noté `AUDIT.md`).
- **Xtream credentials en query string** = inhérent au protocole ; ne pas logger ces URLs.

---

## G. UI — divers

- **`imports`/`errors`/`accounts`** : dictionnaires observés à granularité globale (`AppModel.swift:60-63`) → chaque progression d'import ré-évalue toutes les `SourceSidebarRow` — borné (~dizaines d'écritures) mais même pattern que B4.
- **Recomposition complète du feed à chaque `recordPlayback`/watchlist/dismiss/langue** — `AppModel.swift:179-186, 206-217` : `curationProfile` inclut `library.history`/`watchlist`/`dismissed` → nouveau `CurationRequest` → `Curator.feed` complet → `curatedFeeds` réécrit → rayons visibles peuvent se **réordonner silencieusement** sous l'utilisateur (combiné B4/B5). `Set(library.dismissed)` (≤2000) reconstruit à chaque éval.
- **Hero carousel** : tick 10 s ne change que `index`/`visibleID` → seul `BrowseHero` ré-évalue, les shelves ne bougent pas — bien ; MAIS `onChange(of: items.map(\.id))` (`HeroCarousel.swift:93-98`) recale `visibleID` → une recomposition de feed qui change l'ordre des highlights fait **sauter le carousel** ; chaque avancée détruit/recrée la `HighlightPage` (`.id(item.id)`, `BrowseScreen.swift:163`) — voulu pour le staggered reveal.
- **`NavigationModel.select` même-section → `popToRoot`** — `LibraryShell.swift:77-81` + `Navigation.swift:61-67` : dépend du `List(selection:)` NSTableView qui peut ne pas délivrer le setter pour une sélection identique → code mort pour le clic utilisateur. *À vérifier en exécution.*
- **« Tout est prêt » retardé par search/curation** — `AppModel.swift:544-554` : `waitForCurrentCatalog(includingSearch: true)` attend `SearchIndex.build` + `CurationIndex.build` sur tout le catalogue → plusieurs secondes à 100k+ pendant que l'étape affichée reste « Mise à jour du guide TV… » à 98 %. **Fix** : stage `.finalizing` ou ne pas inclure search/curation dans `.finished`.
- **`onContinuousHover` → `noteUserActivity()` non throttlé** (~120 Hz) — déjà noté `AUDIT.md`.
- **`errors[id]` localisé** — voir A12.
- **Écarts cosmétiques spec onboarding** — `OnboardingView.swift` : pas de feuille « Bienvenue dans Prism » (3 lignes) du spec ; transition « Tout est prêt » = crossfade `.smooth(0.6)` pas zoom/blur ; `AddSourceView.swift:290-298` « Retour » efface adresse/identifiants mais conserve `file`, `name`, `advanced`, `guideAddress`, `userAgent`.
- **`SourceCard.strokeBorder(lineWidth: 0)`** — vérifier si hairline rendue (déjà noté `AUDIT.md`).
- **`BadgeSpec.id = text`** : doublons → IDs `ForEach` dupliqués (déjà noté `AUDIT.md`).
- **`AgeRatingBadge`** : label absurde pour `TP`/`E`/`Tous publics` (déjà noté `AUDIT.md`).
- **`ExpandableText`** : action accessibilité « Afficher plus » même non tronqué (déjà noté `AUDIT.md`).
- **`HeroCarousel` montre des contrôles morts** quand `isInteractive == false` (déjà noté `AUDIT.md`).
- **`ShelfMenuHeader`** : hint « Choisir une saison » hardcodé sur header générique (déjà noté `AUDIT.md`).
- **`PlaceholderArtwork`** : sélection de style sur titre non trimé (déjà noté `AUDIT.md`).
- **`HeroScrollGesture` axis stickiness**, **`HeroBackdrop` Ken Burns 1.025 vs spec 1.06**, **dérive tokens vs spec** (~10 écarts) — déjà notés `AUDIT.md`, non revérifiés.

---

## H. Déjà documenté dans `AUDIT.md` (1ʳᵉ passe) — confirmé présent, non dupliqué

| Finding | Statut |
|---|---|
| `VLCEngine.pause()` no-op live/chargement | Non revérifié — probablement encore présent |
| Live `fallbackURLs` jamais essayées après premier frame | Non revérifié |
| Pause pendant chargement → plan d'essai grippé | Non revérifié |
| Reconnect planifié jamais annulé | Non revérifié |
| VLC `.stopped` → `.ended` inconditionnel | Non revérifié |
| VLC timeshift timebase non vérifié | Non revérifié — *à vérifier sur device* |
| VLC headers (Cookie/Authorization perdus) | Non revérifié |
| `play()` depuis `.ended` race seek async | Non revérifié |
| VLC stall-détect faux positif possible | Non revérifié — *à vérifier sur device* |
| VLC `trackSignature` counts égaux → `.tracksChanged` jamais émis | Non revérifié |
| VOD `.failed` mid-playback → changement moteur définitif | Non revérifié |
| AirPlay inerte pour VLC | Non revérifié |
| `stop()` laisse état stale | Non revérifié |
| `reconcileMediaIdentities` perd alias éditoriaux | Non revérifié |
| Refresh EPG en vol ressuscite après `forget` | Non revérifié |
| `SearchIndex.substringSearch` O(tokens × wordCount) | Atténué (memmem) — fallback reste coûteux |
| `Catalog.related` fold genres sur MainActor | Non revérifié |
| `EPGGuide.resolveEPGID` non mémoïsé | Corrigé (22/11) selon AUDIT.md |
| `EPGGuide.merging` re-trie | Corrigé (22/11) selon AUDIT.md |
| `sportsSchedule` ~2M classifications | Corrigé (22/11) selon AUDIT.md |
| Download M3U octet par octet | Corrigé (22/11) selon AUDIT.md |
| `LenientValue.day` epoch bug | Confirmé + étendu (hh/mm/ss non validés) |
| `Gzip.isCompressed` rate zlib | Confirmé présent |
| `finishPrograms` O(n²) | Confirmé présent |
| `user-agent` seuil >4 attributs | Confirmé présent |
| `encodedData` bufferise tout | Confirmé présent |
| `PosterWall` re-raster | Confirmé présent (ampleur précisée : ~58 Mo) |
| `TitleLogo` ignore Reduce Motion | Confirmé présent |
| `subtitleStyle` VLC mort | Confirmé présent |
| `contentAspectRatio`/`videoSize` stale | Confirmé présent |
| `supportsTimeshift` mort | Confirmé présent |
| Up-next sans countdown | Confirmé présent |
| `LibraryStore.saveNow` sur main | Corrigé (22/11) — encode+write déportés ; mais `snapshot()` trie encore sur main (B2) |
| `TMDBClient.cache` non borné | Confirmé présent |
| `DiscoveryBuilder.local` rescan | Obsolète (Curator) — mais `Discovery.swift` entier est dead code |
| Tokens/spec écarts, divers cosmétiques | Non revérifiés |

---

## I. Plan de correction priorisé

### P0 — quick wins, impact immédiat

| # | Fix | Findings | Effort |
|---|---|---|---|
| 1 | `XtreamDecoder.elements` : erreur sur `user_info`/auth au lieu de `[]` | A1 | S |
| 2 | `ImagePipeline.warm()` sur visibilité des shelves (infra existe) | D2 | M |
| 3 | Cache négatif URLs images (`failedURLs` TTL session) | D1 | M |
| 4 | `continueWatching`/`latestProgress`/`snapshot()` : mémoïser ou `.task @concurrent` ; `isPageActive` guard | B2, B9 | M |
| 5 | `Shelf.scrollPosition` → variante `id:` ou `ScrollPosition` piloté au clic | B3 | M |
| 6 | VLC `timeChangeUpdateInterval = 0.25` + throttle `.time` ; seek confirmé ±1 s | E1, E2 | M |
| 7 | Buffer live HLS 15-30 s / `automaticallyWaitsToMinimizeStalling` | E3 | S |
| 8 | XMLTV : `shouldProcessNamespaces` ou strip préfixe | A2 | S |
| 9 | `Gzip.decompress` : cap sortie ~1-2 Go + réserve réduite | C7 | S |
| 10 | `M3UParser.urlLine` : `pending = nil` sur échec | A4 | S |

### P1 — structurel

| # | Fix | Findings | Effort |
|---|---|---|---|
| 11 | Borner décodage caches (CatalogCache/EPGCache/cachedCatalogs/cachedGuide ~4 segments) | C1 | M |
| 12 | `@concurrent` sur `XtreamDecoder` + `checkCancellation` ; libérer `data` avant mapping | C2, C3 | M |
| 13 | Plafonner/évincer pages `PageStack` + sections `visited` | B1 | M-L |
| 14 | `curatedFeeds` par scope ; mémoïser `Curator.candidates` par (kind, facet) | B4, B5 | M |
| 15 | `DetailRepository`/`MetadataRepository`/`TMDBClient` : caches bornés LRU + purge disque TTL | C5 | M |
| 16 | Mode dégradé catalogues sans artwork (placeholders monogramme) | B10 | M |
| 17 | `TitleNormalizer` cache par import ; `ProviderSynopsis.cleaned` mémoïsé | B11, B12 | M |
| 18 | EPG `inFlight` dedup par source + paralléliser URLs (`withTaskGroup`) | F | M |
| 19 | `restartOnboarding` sur dernière source ; « 0 titres » ; datepicker guide ; stale-while-revalidate recherche ; `update` retour Bool | A3-A8 | S chacun |
| 20 | Sharder/paralleliser groupement `CatalogBuilder` ; mesurer pic rebuild | B9, C5 | L |
| 21 | `ImagePipeline.encodedData` → `session.bytes` + cap ; `prefetchFinished` race ; `blursArtwork` épisodes | C4, D3, B7 | M |

### P2 — polish

| # | Fix | Findings |
|---|---|---|
| 22 | Suspendre hover-lift pendant scroll (`isScrolling` @Entry) ; menu tuile paresseux ; `isFavorite` Set | B6, B8 |
| 23 | `PosterWall` : sur-échantillonnage + occlusion + rasterizationScale | C6 |
| 24 | PiP reset dans `beginAttempt` ; tolérance seek VOD AVF 1-2 s ; seeks `isRepeat`/throttle ; `videoSize`/`contentAspectRatio` reset | E4-E6, E8 |
| 25 | VLC : cache `seekableRange`/tracks, `subtitleStyle` implémenter ou griser, `buffered` réel | E1, E7 |
| 26 | `snapshot()`/`LibraryFile` construction hors main ; `watched` plafond + purge `apply` | B2, C5 |
| 27 | `imports[id]` throttle ; refreshAll sémaphore ; `isRefreshingGuide` compteur | B17, F |
| 28 | Keychain : mémoïser secrets + logger statuts ; `lastFetched` sans décoder tout le cache | F |
| 29 | `TitleNormalizer`/`ContentID.parts`/`EPGProgram.id` allocations ; `providerLanguages` cache ; `titles(in:)` lazy | B14-B17 |
| 30 | Dead code : `Discovery.swift`, `CompressedCodableFile.swift`, `validate`/`SourceValidation`, `moveSources`, `hasCompletedOnboarding`, `cachedAverageColor`, `NoiseTexture`, prefetch si non câblé | A12, D5 |
| 31 | i18n : `errors[id]` via `displayError` ; « Tout est prêt » stage `.finalizing` ; feuille bienvenue spec | A12, G |

### À mesurer avec Instruments (avant/après)

- **View updates** pendant scroll shelf + page (B3, B6, B14)
- **Hitches** pendant lecture → retour Home (B2, B9)
- **Pic mémoire** import 100k+ et lancement multi-sources (C1, C2, C5)
- **Frames** pendant PosterWall et hero carousel (C6)
- **Time Profiler** : `Curator.feed`, `CatalogBuilder.build`, `SearchIndex` (B5, B9, B11)
- **Confirmations device** : VLC timeshift timebase, stall-détect faux positif, HLS headers→segments, `List(selection:)` re-clic

---

## J. Points forts vérifiés (ne pas casser)

- **Zéro force unwrap** sur données externes dans tout `Sources/` (1 seul : URL constante en dur dans `DemoContent.swift:12`).
- **Pipeline d'images exemplaire** : decode keys bucketées, `CGImageSourceCreateThumbnailAtIndex` (jamais full-res), fetches dédupliqués avec annulation par waiters, NSCache bytes + disque LRU SHA-256, decode off-main via `ImageDecodeQueue` (6) `@concurrent` + autoreleasepool, `blursArtwork(sized:)` partage le décodage net, hero progressive (preview+original), `showsSameArtwork` anti-flicker.
- **Recherche** : vraie index inversée (mots triés + posting lists + comptage), multi-token AND driver smallest-posting, TopK borné, `@concurrent` + debounce 150 ms + cancellation.
- **EPGGuide** : index par chaîne, recherche binaire, `ResolutionMemo`, merge O(n) — pas de scan linéaire.
- **Catalog** : lookups O(1), `related(to:)` borné, `parallelSortedIndices`/`topIndices`.
- **Concurrence** : `@concurrent`/`Sendable` corrects, `Task.checkCancellation` aux frontières, `Catalog` immuable, `AppModel` sérialise publications sur MainActor avec guards de révision, annulation disciplinée (`onTermination`, tasks non structurées mais vérifient `isCancelled`).
- **Player** : zéro fuite (KVO/notifications/time observers invalidés), gardes de génération anti-events stale, teardown current+retiring, transitions last-frame au zap, state machine auto-hide (deadline prolongé pendant sleep), triple-état `MediaTrack.ID??` correctement déballé, scrubber monté seulement contrôles visibles.
- **M3U parser** : bytes + `memchr`, BOM/CRLF/Latin-1/guillemets non fermés gérés, `@concurrent` de bout en bout.
- **Bootstrap/import** : `CatalogBuilder`/`SearchIndex`/`CurationIndex`/`EPGGuide.merged`/`sportsSchedule`/`DetailEpisodeInventory.build`/`Curator.collection` tous hors main ; compteurs d'import throttlés aux changements d'étape (~4-6) + progression 512 Ko.
- **Navigation** : pages sous-jacentes gardent leur scroll, lookup `Catalog.title` O(1), `removeRoutes` purge les routes des sources supprimées, ⌘[ + Échap corrects.
- **Accessibilité/Reduce Motion** : respecté quasi systématiquement (cards, hero, PageDots, PosterWall, badges, boutons) ; labels sur contrôles icône-seuls ; lazy containers partout.
- **Suppression source** : nettoie keychain, catalog cache, EPG cache, meta JSON, sources.json, catégories masquées, routes — correct.
- **Validation formulaire** : uniquement après « Se connecter » — pas à chaque frappe.
