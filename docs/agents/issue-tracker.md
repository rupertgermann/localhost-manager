# Lokaler Markdown-Tracker

Jedes Vorhaben erhält einen Ordner unter `.scratch/<vorhaben>/`.
Die Spezifikation liegt in `spec.md`, jedes Ticket in `issues/NN-<titel>.md`.
Die Nummerierung beginnt bei `01`.

Bei Umsetzungstickets steht der Triagewert oben in `Status:`.
Die gültigen Werte stehen in `triage-labels.md`.
Kommentare werden unter `## Comments` angehängt.

## Wayfinder

Die Entscheidungskarte liegt in `map.md`. Jedes Entscheidungsticket
enthält seine Frage unter `## Question` und einen `Type:` aus
`research`, `prototype`, `grilling` oder `task`.

Neue Entscheidungstickets beginnen mit `Status: open`.
`Blocked by:` nennt gegebenenfalls die Nummern der vorausgesetzten Tickets.
Als Nächstes ist das erste offene, unbeanspruchte Ticket an der Reihe,
dessen Voraussetzungen alle `resolved` sind.

Vor Arbeitsbeginn `Assignee:` eintragen und `Status: claimed` speichern.
Zum Abschluss die Antwort unter `## Answer` ergänzen, `Status: resolved`
setzen und das Ticket mit Titel und Kurzfassung in der Karte verlinken.
