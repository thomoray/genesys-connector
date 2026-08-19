// This file contains your Data Connector logic
[Version = "1.0.0"]
section GenesysConnector;

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

[DataSource.Kind = "GenesysConnector", Publish = "GenesysConnector.Publish"]
shared GenesysConnector.Contents = Value.ReplaceType(GenesysNavTable, GenesysNavTableType);

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
    Documentation.LongDescription = "Connects to the Genesys Cloud Analytics API and returns Interactions (conversation detail) and Queue (interval performance) data for the selected date range."
];

GenesysNavTable = (Region as text, optional StartDate as date, optional EndDate as date) as table =>
    let
        objects = #table(
            {"Name", "Key", "Data", "ItemKind", "ItemName", "IsLeaf"},
            {
                {"Interactions", "Interactions", GetInteractions(Region, StartDate, EndDate), "Table", "Table", true},
                {"Queue", "Queue", GetQueue(Region, StartDate, EndDate), "Table", "Table", true}
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
// Queue (interval aggregate) query
// ===========================================================================

// One row per Queue x Media Type x interval bucket. Built from
// /analytics/conversations/aggregates/query, whose "t*" metrics report
// {count, sum, min, max} in MILLISECONDS (count doubles as the occurrence
// count for that state - e.g. tAnswered.count is the number answered) and
// whose "n*" counters report their total via .count. oServiceLevel is an
// objective-type metric reporting .ratio/.target rather than count/sum.
// Service Level % and Transfer are the least certain mappings here - verify
// them against a known-good report in your tenant before trusting them.
QueueGranularity = "PT30M";

QueueMetrics = {
    "nOffered", "tAnswered", "tAbandon", "tHandle", "tTalk", "tHeld", "tAcw", "tWait",
    "oServiceLevel", "nBlindTransferred", "nConsultTransferred"
};

QueueColumns = {
    "QueueId", "MediaType", "Interval",
    "Offer", "Answer", "Answer %", "Abandon", "Abandon %", "ASA",
    "Service Level %", "Service Level Target %",
    "Avg Wait", "Avg Handle", "Avg Talk", "Avg Hold", "Avg ACW",
    "Hold", "Transfer"
};

GetQueue = (Region as text, optional StartDate as date, optional EndDate as date) as table =>
    let
        Domain = Region,
        Token = GetToken(Domain),

        _EndDate = if EndDate <> null then EndDate else Date.From(DateTimeZone.UtcNow()),
        _StartDate = if StartDate <> null then StartDate else Date.AddDays(_EndDate, -7),

        DayCount = Duration.Days(_EndDate - _StartDate) + 1,
        Days = List.Dates(_StartDate, DayCount, #duration(1, 0, 0, 0)),

        DayResults = List.Transform(
            Days,
            each QueueAggregatesForDay(Domain, Token, DateTime.From(_), DateTime.From(_) + #duration(1, 0, 0, 0))
        ),
        AllRows = List.Combine(DayResults),

        AsTable = Table.FromRecords(AllRows, QueueColumns, MissingField.UseNull),
        SplitInterval = Table.SplitColumn(AsTable, "Interval", Splitter.SplitTextByDelimiter("/"), {"Interval Start", "Interval End"}),

        WithQueueNames = Table.NestedJoin(SplitInterval, {"QueueId"}, QueueNameMap(Domain, Token), {"QueueId"}, "QueueLookup", JoinKind.LeftOuter),
        ExpandQueue = Table.ExpandTableColumn(WithQueueNames, "QueueLookup", {"QueueName"}, {"QueueName"}),

        Typed = Table.TransformColumnTypes(ExpandQueue, {
            {"Interval Start", type datetimezone},
            {"Interval End", type datetimezone},
            {"MediaType", type text},
            {"QueueId", type text},
            {"QueueName", type text},
            {"Offer", Int64.Type},
            {"Answer", Int64.Type},
            {"Answer %", type number},
            {"Abandon", Int64.Type},
            {"Abandon %", type number},
            {"ASA", type duration},
            {"Service Level %", type number},
            {"Service Level Target %", type number},
            {"Avg Wait", type duration},
            {"Avg Handle", type duration},
            {"Avg Talk", type duration},
            {"Avg Hold", type duration},
            {"Avg ACW", type duration},
            {"Hold", Int64.Type},
            {"Transfer", Int64.Type}
        }),

        WithIntervalComplete = Table.AddColumn(
            Typed, "Interval Complete",
            each [#"Interval End"] <> null and [#"Interval End"] <= DateTimeZone.UtcNow(),
            type logical
        ),

        Reordered = Table.ReorderColumns(WithIntervalComplete, {
            "Interval Start", "Interval End", "Interval Complete", "MediaType", "QueueId", "QueueName",
            "Offer", "Answer", "Answer %", "Abandon", "Abandon %", "ASA",
            "Service Level %", "Service Level Target %",
            "Avg Wait", "Avg Handle", "Avg Talk", "Avg Hold", "Avg ACW", "Hold", "Transfer"
        })
    in
        Reordered;

// One /aggregates/query call for a UTC day, flattened to one record per
// Queue x Media Type x interval bucket.
QueueAggregatesForDay = (Domain as text, Token as text, DayStart as datetime, DayEnd as datetime) as list =>
    let
        Interval = DateTime.ToText(DayStart, "yyyy-MM-ddTHH:mm:ss") & ".000Z/" & DateTime.ToText(DayEnd, "yyyy-MM-ddTHH:mm:ss") & ".000Z",

        Response = ApiRequest(Domain, Token, "/api/v2/analytics/conversations/aggregates/query", [
            interval = Interval,
            granularity = QueueGranularity,
            timeZone = "UTC",
            groupBy = {"queueId", "mediaType"},
            metrics = QueueMetrics
        ]),
        Results = Response[results]? ?? {}
    in
        List.Combine(List.Transform(Results, each FlattenQueueGroup(_[group], _[data])));

FlattenQueueGroup = (Group as record, DataList as list) as list =>
    List.Transform(
        DataList,
        each
            let
                Bucket = _,
                Metrics = Bucket[metrics]? ?? {},

                OfferCount = MetricField(Metrics, "nOffered", "count"),
                AnswerCount = MetricField(Metrics, "tAnswered", "count"),
                AnswerSum = MetricField(Metrics, "tAnswered", "sum"),
                AbandonCount = MetricField(Metrics, "tAbandon", "count"),
                HandleSum = MetricField(Metrics, "tHandle", "sum"),
                HandleCount = MetricField(Metrics, "tHandle", "count"),
                TalkSum = MetricField(Metrics, "tTalk", "sum"),
                TalkCount = MetricField(Metrics, "tTalk", "count"),
                HeldSum = MetricField(Metrics, "tHeld", "sum"),
                HeldCount = MetricField(Metrics, "tHeld", "count"),
                AcwSum = MetricField(Metrics, "tAcw", "sum"),
                AcwCount = MetricField(Metrics, "tAcw", "count"),
                WaitSum = MetricField(Metrics, "tWait", "sum"),
                WaitCount = MetricField(Metrics, "tWait", "count"),
                SlaRatio = MetricField(Metrics, "oServiceLevel", "ratio"),
                SlaTarget = MetricField(Metrics, "oServiceLevel", "target"),
                BlindTransfers = MetricField(Metrics, "nBlindTransferred", "count"),
                ConsultTransfers = MetricField(Metrics, "nConsultTransferred", "count")
            in
                [
                    QueueId = Record.FieldOrDefault(Group, "queueId", null),
                    MediaType = Record.FieldOrDefault(Group, "mediaType", null),
                    Interval = Bucket[interval]?,
                    Offer = OfferCount,
                    Answer = AnswerCount,
                    #"Answer %" = SafeRatio(AnswerCount, OfferCount),
                    Abandon = AbandonCount,
                    #"Abandon %" = SafeRatio(AbandonCount, OfferCount),
                    ASA = MsToDuration(SafeRatio(AnswerSum, AnswerCount)),
                    #"Service Level %" = if SlaRatio <> null then SlaRatio * 100 else null,
                    #"Service Level Target %" = if SlaTarget <> null then SlaTarget * 100 else null,
                    #"Avg Wait" = MsToDuration(SafeRatio(WaitSum, WaitCount)),
                    #"Avg Handle" = MsToDuration(SafeRatio(HandleSum, HandleCount)),
                    #"Avg Talk" = MsToDuration(SafeRatio(TalkSum, TalkCount)),
                    #"Avg Hold" = MsToDuration(SafeRatio(HeldSum, HeldCount)),
                    #"Avg ACW" = MsToDuration(SafeRatio(AcwSum, AcwCount)),
                    Hold = HeldCount,
                    Transfer = (if BlindTransfers <> null then BlindTransfers else 0) + (if ConsultTransfers <> null then ConsultTransfers else 0)
                ]
    );

// Finds one named metric in an AggregateMetricData list and reads one field
// (count/sum/min/max/ratio/target/...) out of its stats record.
MetricField = (Metrics as list, Name as text, Field as text) as nullable number =>
    let
        Matches = List.Select(Metrics, each Record.FieldOrDefault(_, "metric", null) = Name),
        Stats = if List.Count(Matches) > 0 then Matches{0}[stats]? else null
    in
        if Stats <> null then Record.FieldOrDefault(Stats, Field, null) else null;

SafeRatio = (Numerator as nullable number, Denominator as nullable number) as nullable number =>
    if Numerator <> null and Denominator <> null and Denominator <> 0 then Numerator / Denominator else null;

// Genesys reports time-metric stats in milliseconds; convert to an M duration.
MsToDuration = (Ms as nullable number) as nullable duration =>
    if Ms = null then null else #duration(0, 0, 0, Ms / 1000);

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
// the connector's UsernamePassword credential (see GenesysConnector below) -
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

GenesysConnector = [
    TestConnection = (dataSourcePath) =>
        let
            Json = Json.Document(dataSourcePath)
        in
            {"GenesysConnector.Contents", Json[Region]},
    Authentication = [
        UsernamePassword = [
            UsernameLabel = "Client ID",
            PasswordLabel = "Client Secret"
        ]
    ],
    Label = "Genesys Cloud"
];

// Data Source UI publishing description
GenesysConnector.Publish = [
    Beta = true,
    Category = "Online Services",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl = "https://developer.genesys.cloud/",
    SourceImage = GenesysConnector.Icons,
    SourceTypeImage = GenesysConnector.Icons
];

GenesysConnector.Icons = [
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
