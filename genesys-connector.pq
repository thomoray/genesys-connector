// This file contains your Data Connector logic
[Version = "1.0.0"]
section genesys-connector;

[DataSource.Kind="genesys-connector", Publish="genesys-connector.Publish"]
shared genesys-connector.Contents = (optional message as text) =>
    let
        _message = if (message <> null) then message else "(no message)",
        a = "Hello from genesys-connector: " & _message
    in
        a;

// Data Source Kind description
genesys-connector = [
    Authentication = [
        // Key = [],
        // UsernamePassword = [],
        // Windows = [],
        Anonymous = []
    ]
];

// Data Source UI publishing description
genesys-connector.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl = "https://powerbi.microsoft.com/",
    SourceImage = genesys-connector.Icons,
    SourceTypeImage = genesys-connector.Icons
];

genesys-connector.Icons = [
    Icon16 = { Extension.Contents("genesys-connector16.png"), Extension.Contents("genesys-connector20.png"), Extension.Contents("genesys-connector24.png"), Extension.Contents("genesys-connector32.png") },
    Icon32 = { Extension.Contents("genesys-connector32.png"), Extension.Contents("genesys-connector40.png"), Extension.Contents("genesys-connector48.png"), Extension.Contents("genesys-connector64.png") }
];
