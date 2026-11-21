# Prism

Lecteur IPTV natif en français pour macOS 26 et ultérieur. Prism réunit les chaînes, films et séries de vos listes M3U et comptes Xtream Codes. Il lit les programmes de vos sources et inclut une démo pour essayer l’interface.

- **Accueil** · Reprise de lecture, sélection française, incontournables américains et découvertes internationales. Le menu sur l’accueil permet de choisir les recommandations en français, en anglais ou dans les deux langues.
- **Fiches** · Une entrée par œuvre lorsque les données permettent le rapprochement. Au lancement de la lecture, choisissez parmi les versions disponibles pour ce titre ou cet épisode. Le lecteur propose également les pistes audio et les sous-titres signalés par le flux.
- **Direct** · Guide XMLTV, favoris, changement de chaîne au clavier, source préférée et replay lorsqu’une archive est disponible.
- **Sport** · Affiches et horaires dans l’accueil et dans une rubrique dédiée. Calendrier et derniers résultats de la Ligue des champions, de la Ligue 1, de la NBA et de la boxe, avec un accès aux diffusions identifiées dans le guide IPTV.
- **Sources** · Saisie ou collage des codes Xtream, listes M3U et réglages XMLTV. Le filtre d’une source permet de masquer des catégories avant le regroupement du catalogue.
- **Bibliothèque** · Ma liste, historique et reprise, conservés sur le Mac. Le lecteur propose l’épisode suivant lorsqu’il est disponible dans l’édition en cours.
- **Lecture** · Fenêtre dédiée, AVFoundation et VLCKit, avec repli automatique. L’enrichissement des fiches par TMDB est facultatif et se configure avec votre clé.

## Données sportives

Les calendriers et résultats proviennent de l’API publique TheSportsDB. L’accès gratuit fournit la prochaine rencontre et la plus récente par compétition. Pour les scores en direct selon la couverture du fournisseur, enregistrez une clé TheSportsDB Premium dans **Réglages → Général → Scores sportifs**. La boxe affiche les combats et les résultats en texte lorsque le fournisseur les renseigne. Les horaires s’affichent dans le fuseau de votre Mac. [Documentation TheSportsDB](https://api.thesportsdb.com/docs/api)

La clé sportive est conservée dans le Trousseau de macOS. Les requêtes à TheSportsDB n’incluent aucun identifiant IPTV.

## Compiler

Depuis la racine, avec Xcode et XcodeGen installés.

```sh
xcodegen generate
xcodebuild -project Prism.xcodeproj -scheme Prism -destination 'platform=macOS' build
cd Packages/PrismKit
swift test
```

## Audit de départ

Le dépôt associait déjà des parseurs et clients IPTV, un catalogue indexé, un cache d’images, des composants SwiftUI et deux moteurs de lecture. Le projet Xcode affichait encore un écran de lancement statique. Les écrans de navigation, l’ajout de source, les fiches, les collections, la recherche et le guide devaient être reliés au modèle et au lecteur.

Les captures macOS locales ont servi à étudier la lisibilité en grand format et l’emplacement des commandes. Les références Mobbin iOS ont éclairé les collections thématiques et l’accès aux saisons. Prism adopte un monogramme, des visuels cadrés et une présentation qui met en évidence les versions IPTV disponibles. [Apple TV sur Mobbin](https://mobbin.com/screens/c58760da-44bb-489d-bb3b-a19c060dfa8f), [Paramount+ sur Mobbin](https://mobbin.com/screens/c75fc6d4-58a0-4794-b0a9-9e3226b34e26), [Tubi sur Mobbin](https://mobbin.com/screens/25fd93a2-e801-4bd1-9a8b-1d931e2175cf)

La revue en fenêtre native comparait l’accueil de Prism, les fiches de Sintel et Caminandes, et le lecteur sur une scène claire aux écrans de l’app TV sur le Mac. Le monogramme graphite, les marges resserrées et les commandes en verre neutre donnent la priorité aux images. L’import Xtream est vérifiable avec un serveur de test local et le parcours démo utilise les courts métrages de Blender Studio.
