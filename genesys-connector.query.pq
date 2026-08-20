// Use this file to write queries to test your data connector.
// Set your Client ID / Client Secret via the Power Query SDK "Set credential"
// command first (see .env for the values) - M cannot read .env directly.
// Nav table keys available: "Interactions", "Queue", "Quality", "ATS".
// ATS takes a 4th optional arg, TimeZone (Olson name, e.g. "Australia/Sydney"),
// which only affects ATS - see the comment on GetATS for its "Date" caveat.
let
    Source = GenesysConnector.Contents("mypurecloud.com.au", #date(2026, 8, 12), #date(2026, 8, 19)),
    Interactions = Source{[Key = "Interactions"]}[Data]
in
    Interactions
