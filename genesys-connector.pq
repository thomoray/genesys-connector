// This file contains your Data Connector logic
[Version = "1.0.0"]
section genesys-connector;

// ===========================================================================
// Configuration
// ===========================================================================

// Genesys Cloud region domains. The connector talks to https://login.<domain>
// (token endpoint) and https://api.<domain> (platform API) for whichever
// region the caller picks. See https://developer.genesys.cloud/platform/api/ .
GenesysRegions = {
    "mypurecloud.com",
    "mypurecloud.ie",
    "mypurecloud.de",
    "mypurecloud.com.au",
    "mypurecloud.jp",
    "usw2.pure.cloud",
    "cac1.pure.cloud",
    "sae1.pure.cloud",
    "euw2.pure.cloud",
    "apne2.pure.cloud",
    "apne3.pure.cloud",
    "aps1.pure.cloud",
    "mec1.pure.cloud"
};

PageSize = 100;

// ===========================================================================
// Exported function
// ===========================================================================

[DataSource.Kind = "genesys-connector", Publish = "genesys-connector.Publish"]
shared genesys-connector.Contents = Value.ReplaceType(GenesysNavTable, GenesysNavTableType);

GenesysNavTableType = type function (
    Region as (type text meta [
        Documentation.FieldCaption = "Region",
        Documentation.FieldDescription = "Genesys Cloud region domain that hosts your org, e.g. mypurecloud.com.au",
        Documentation.AllowedValues = GenesysRegions
    ]),
    optional StartDate as (type date meta [
        Documentation.FieldCaption = "Start Date (UTC)",
        Documentation.FieldDescription = "First day of conversations to include. Defaults to 7 days before End Date."
    ]),
    optional EndDate as (type date meta [
        Documentation.FieldCaption = "End Date (UTC)",
        Documentation.FieldDescription = "Last day of conversations to include. Defaults to today (UTC)."
    ])
) as table meta [
    Documentation.Name = "Genesys Cloud",
    Documentation.LongDescription = "Connects to the Genesys Cloud Analytics API and returns conversation interaction detail for the selected date range."
];

GenesysNavTable = (Region as text, optional StartDate as date, optional EndDate as date) as table =>
    let
        objects = #table(
            {"Name", "Key", "Data", "ItemKind", "ItemName", "IsLeaf"},
            {
                {"Interactions", "Interactions", GetInteractions(Region, StartDate, EndDate), "Table", "Table", true}
            }
        ),
        NavTable = Table.ToNavigationTable(objects, {"Key"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        NavTable;

// ===========================================================================
// Interactions (conversation detail) query
// ===========================================================================

// One row per conversation/participant/session/segment - the finest grain the
// API returns. Aggregate columns from the old CSV export (Total Talk, Total
// Hold, First Queue, etc.) aren't reproduced here: they were derived from this
// same segment-level data, and can be rebuilt with a Group By on
// ConversationId/SegmentType once this shape is validated against real data.
GetInteractions = (Region as text, optional StartDate as date, optional EndDate as date) as table =>
    let
        Domain = Region,
        Token = GetToken(Domain),

        _EndDate = if EndDate <> null then EndDate else Date.From(DateTimeZone.UtcNow()),
        _StartDate = if StartDate <> null then StartDate else Date.AddDays(_EndDate, -7),

        DayCount = Duration.Days(_EndDate - _StartDate) + 1,
        Days = List.Dates(_StartDate, DayCount, #duration(1, 0, 0, 0)),

        DayResults = List.Transform(
            Days,
            each ConversationDetailsForDay(Domain, Token, DateTime.From(_), DateTime.From(_) + #duration(1, 0, 0, 0))
        ),
        AllConversations = List.Combine(DayResults),

        Flattened = FlattenConversations(AllConversations),

        WithQueueNames = Table.NestedJoin(Flattened, {"QueueId"}, QueueNameMap(Domain, Token), {"QueueId"}, "QueueLookup", JoinKind.LeftOuter),
        ExpandQueue = Table.ExpandTableColumn(WithQueueNames, "QueueLookup", {"QueueName"}, {"QueueName"}),

        WithWrapUp = Table.NestedJoin(ExpandQueue, {"WrapUpCode"}, WrapUpCodeMap(Domain, Token), {"WrapUpCodeId"}, "WrapUpLookup", JoinKind.LeftOuter),
        ExpandWrapUp = Table.ExpandTableColumn(WithWrapUp, "WrapUpLookup", {"WrapUpCodeName"}, {"WrapUpCodeName"}),

        Typed = Table.TransformColumnTypes(ExpandWrapUp, {
            {"ConversationId", type text},
            {"ConversationStart", type datetimezone},
            {"ConversationEnd", type datetimezone},
            {"ParticipantId", type text},
            {"UserId", type text},
            {"Purpose", type text},
            {"SessionId", type text},
            {"MediaType", type text},
            {"Direction", type text},
            {"Ani", type text},
            {"Dnis", type text},
            {"SessionDnis", type text},
            {"Remote", type text},
            {"FlowOutType", type text},
            {"DeliveryStatus", type text},
            {"SegmentStart", type datetimezone},
            {"SegmentEnd", type datetimezone},
            {"SegmentType", type text},
            {"QueueId", type text},
            {"DisconnectType", type text},
            {"WrapUpCode", type text},
            {"WrapUpNote", type text}
        }),

        WithDuration = Table.AddColumn(
            Typed,
            "Duration",
            each if [SegmentEnd] <> null and [SegmentStart] <> null then [SegmentEnd] - [SegmentStart] else null,
            type duration
        )
    in
        WithDuration;

// Fetches every page of /analytics/conversations/details/query for one UTC day.
ConversationDetailsForDay = (Domain as text, Token as text, DayStart as datetime, DayEnd as datetime) as list =>
    let
        Interval = DateTime.ToText(DayStart, "yyyy-MM-ddTHH:mm:ss") & ".000Z/" & DateTime.ToText(DayEnd, "yyyy-MM-ddTHH:mm:ss") & ".000Z",

        FetchPage = (PageNumber as number) =>
            ApiRequest(Domain, Token, "/api/v2/analytics/conversations/details/query", [
                interval = Interval,
                order = "asc",
                orderBy = "conversationStart",
                paging = [pageSize = PageSize, pageNumber = PageNumber]
            ]),

        Pages = List.Generate(
            () => [Page = 1, Response = FetchPage(1)],
            each [Response][conversations]? <> null and List.Count([Response][conversations]) > 0,
            each [Page = [Page] + 1, Response = FetchPage([Page] + 1)],
            each [Response][conversations]?
        )
    in
        List.Combine(Pages);

// Expands the nested conversations/participants/sessions/segments arrays into
// one flat row per segment.
FlattenConversations = (Conversations as list) as table =>
    let
        Base = Table.FromRecords(Conversations, {"conversationId", "conversationStart", "conversationEnd", "participants"}, MissingField.UseNull),
        Renamed = Table.RenameColumns(Base, {{"conversationId", "ConversationId"}, {"conversationStart", "ConversationStart"}, {"conversationEnd", "ConversationEnd"}}),

        ExpandParticipants = Table.ExpandListColumn(Renamed, "participants"),
        ParticipantFields = Table.ExpandRecordColumn(
            ExpandParticipants, "participants",
            {"participantId", "userId", "purpose", "sessions"},
            {"ParticipantId", "UserId", "Purpose", "Sessions"}
        ),

        ExpandSessions = Table.ExpandListColumn(ParticipantFields, "Sessions"),
        SessionFields = Table.ExpandRecordColumn(
            ExpandSessions, "Sessions",
            {"sessionId", "mediaType", "direction", "ani", "dnis", "sessionDnis", "remote", "flowOutType", "deliveryStatus", "segments"},
            {"SessionId", "MediaType", "Direction", "Ani", "Dnis", "SessionDnis", "Remote", "FlowOutType", "DeliveryStatus", "Segments"}
        ),

        ExpandSegments = Table.ExpandListColumn(SessionFields, "Segments"),
        SegmentFields = Table.ExpandRecordColumn(
            ExpandSegments, "Segments",
            {"segmentStart", "segmentEnd", "segmentType", "queueId", "disconnectType", "wrapUpCode", "wrapUpNote"},
            {"SegmentStart", "SegmentEnd", "SegmentType", "QueueId", "DisconnectType", "WrapUpCode", "WrapUpNote"}
        )
    in
        SegmentFields;

// ===========================================================================
// Reference data lookups (Queue name, Wrap-up code name)
// ===========================================================================

QueueNameMap = (Domain as text, Token as text) as table =>
    let
        Entities = List.Combine(GetAllPages(Domain, Token, "/api/v2/routing/queues")),
        AsTable = Table.FromRecords(Entities, {"id", "name"}, MissingField.UseNull)
    in
        Table.RenameColumns(AsTable, {{"id", "QueueId"}, {"name", "QueueName"}});

WrapUpCodeMap = (Domain as text, Token as text) as table =>
    let
        Entities = List.Combine(GetAllPages(Domain, Token, "/api/v2/routing/wrapupcodes")),
        AsTable = Table.FromRecords(Entities, {"id", "name"}, MissingField.UseNull)
    in
        Table.RenameColumns(AsTable, {{"id", "WrapUpCodeId"}, {"name", "WrapUpCodeName"}});

// Pages through a GET list endpoint (?pageNumber=&pageSize=) until an empty
// page of entities comes back. Returns a list of per-page entity lists.
GetAllPages = (Domain as text, Token as text, BasePath as text) as list =>
    let
        Separator = if Text.Contains(BasePath, "?") then "&" else "?",
        FetchPage = (PageNumber as number) =>
            ApiRequest(Domain, Token, BasePath & Separator & "pageNumber=" & Text.From(PageNumber) & "&pageSize=100", null),

        Pages = List.Generate(
            () => [Page = 1, Response = FetchPage(1)],
            each [Response][entities]? <> null and List.Count([Response][entities]) > 0,
            each [Page = [Page] + 1, Response = FetchPage([Page] + 1)],
            each [Response][entities]?
        )
    in
        Pages;

// ===========================================================================
// Auth + low-level HTTP
// ===========================================================================

// OAuth2 client-credentials grant. Client ID / Client Secret are supplied via
// the connector's UsernamePassword credential (see genesys-connector below) -
// set them through the Power Query SDK "Set credential" command or the Power
// BI Desktop connect dialog, not from this project's .env file (M has no
// access to process environment variables).
GetToken = (Domain as text) as text =>
    let
        Credential = Extension.CurrentCredential(),
        ClientId = Credential[Username],
        ClientSecret = Credential[Password],
        BasicAuth = "Basic " & Binary.ToText(Text.ToBinary(ClientId & ":" & ClientSecret), BinaryEncoding.Base64),

        RawResponse = Web.Contents(
            "https://login." & Domain & "/oauth/token",
            [
                Headers = [
                    Authorization = BasicAuth,
                    #"Content-Type" = "application/x-www-form-urlencoded"
                ],
                Content = Text.ToBinary("grant_type=client_credentials"),
                ManualStatusHandling = {400, 401, 403}
            ]
        ),
        Status = Value.Metadata(RawResponse)[Response.Status]?
    in
        if Status = null or Status = 200 then Json.Document(RawResponse)[access_token]
        else error Error.Record("Genesys.Auth", "Failed to obtain an access token from Genesys Cloud. Check the Client ID / Client Secret and Region.", Text.FromBinary(RawResponse));

// Generic authenticated call against the Genesys Cloud platform API. Pass a
// record as Body for a POST with a JSON payload, or null for a GET.
ApiRequest = (Domain as text, Token as text, Path as text, optional Body as nullable record) as any =>
    let
        BaseOptions = [
            Headers = [
                Authorization = "Bearer " & Token,
                #"Content-Type" = "application/json",
                Accept = "application/json"
            ],
            ManualStatusHandling = {400, 401, 403, 404, 429, 500}
        ],
        Options = if Body <> null then BaseOptions & [Content = Json.FromValue(Body)] else BaseOptions,

        RawResponse = Web.Contents("https://api." & Domain & Path, Options),
        Status = Value.Metadata(RawResponse)[Response.Status]?
    in
        if Status = null or Status = 200 then Json.Document(RawResponse)
        else error Error.Record("Genesys.Api", "Genesys Cloud API request failed (" & Text.From(Status) & ") for " & Path, Text.FromBinary(RawResponse));

// ===========================================================================
// Data Source Kind / Publish
// ===========================================================================

genesys-connector = [
    TestConnection = (dataSourcePath) =>
        let
            Json = Json.Document(dataSourcePath)
        in
            {"genesys-connector.Contents", Json[Region]},
    Authentication = [
        UsernamePassword = [
            UsernameLabel = "Client ID",
            PasswordLabel = "Client Secret"
        ]
    ],
    Label = "Genesys Cloud"
];

// Data Source UI publishing description
genesys-connector.Publish = [
    Beta = true,
    Category = "Online Services",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl = "https://developer.genesys.cloud/",
    SourceImage = genesys-connector.Icons,
    SourceTypeImage = genesys-connector.Icons
];

genesys-connector.Icons = [
    Icon16 = { Extension.Contents("genesys-connector16.png"), Extension.Contents("genesys-connector20.png"), Extension.Contents("genesys-connector24.png"), Extension.Contents("genesys-connector32.png") },
    Icon32 = { Extension.Contents("genesys-connector32.png"), Extension.Contents("genesys-connector40.png"), Extension.Contents("genesys-connector48.png"), Extension.Contents("genesys-connector64.png") }
];

// ===========================================================================
// Standard navigation table helper (Microsoft Data Connectors SDK sample)
// ===========================================================================

Table.ToNavigationTable = (
    table as table,
    keyColumns as list,
    nameColumn as text,
    dataColumn as text,
    itemKindColumn as text,
    itemNameColumn as text,
    isLeafColumn as text
) as table =>
    let
        TableType = Value.Type(table),
        NewTableType = Type.AddTableKey(TableType, keyColumns, true) meta [
            NavigationTable.NameColumn = nameColumn,
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn,
            Preview.DelayColumn = itemNameColumn,
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        NavigationTable = Value.ReplaceType(table, NewTableType)
    in
        NavigationTable;
