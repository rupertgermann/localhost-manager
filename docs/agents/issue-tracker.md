# Issue-Tracker auf GitHub

Tickets und Spezifikationen sind öffentliche GitHub Issues in `rupertgermann/localhost-manager`. Verwende `gh` und gib bei den folgenden Befehlen `--repo rupertgermann/localhost-manager` an.

## Issues

- Veröffentliche Tickets und Spezifikationen mit `gh issue create --title "..." --body-file <datei>`.
- Lies ein Ticket mit `gh issue view <nummer> --json number,title,body,labels,comments`.
- Liste Tickets mit `gh issue list --state open` und filtere bei Bedarf mit `--label`.
- Kommentiere mit `gh issue comment <nummer> --body-file <datei>`.
- Setze oder entferne die [Triage-Labels](triage-labels.md) mit `gh issue edit <nummer> --add-label <label>` oder `--remove-label <label>`.
- Dokumentiere die Lösung oder den Grund für die Schließung als Kommentar und schließe das Issue mit `gh issue close <nummer>`.

**PRs as a request surface: no.**

## Wayfinder

- Die Entscheidungskarte ist ein Issue mit dem Label `wayfinder:map`. Entscheidungstickets sind Sub-Issues und tragen je nach Typ `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling` oder `wayfinder:task`.
- Verknüpfe neue Sub-Issues mit `gh issue create --parent <karte>` und bestehende mit `gh issue edit <karte> --add-sub-issue <ticket>`.
- Erfasse Abhängigkeiten mit `gh issue edit <ticket> --add-blocked-by <blocker>`. Das nächste Ticket ist in Kartenreihenfolge das erste offene, nicht zugewiesene Sub-Issue ohne offene Blocker.
- Übernimm das Ticket mit `gh issue edit <ticket> --add-assignee @me`. Kommentiere die Entscheidung, schließe das Ticket und verlinke es mit einer Kurzfassung in der Karte.
