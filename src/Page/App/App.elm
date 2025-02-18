module Page.App.App exposing (..)

import Bool.Extra as BX
import Browser.Dom as Dom
import Browser.Events as Events
import Config
import EndPoint as EP
import Html exposing (..)
import Html.Attributes exposing (alt, classList, href, placeholder, property, spellcheck, src, target, value)
import Html.Events exposing (onBlur, onClick, onFocus, onInput)
import Json.Decode as Decode exposing (Decoder, bool, float, int, list, null, nullable, oneOf, string)
import Json.Decode.Extra exposing (datetime)
import Json.Decode.Pipeline exposing (required, requiredAt)
import Json.Encode as Encode
import Json.Encode.Extra as EX
import List.Extra as LX
import Maybe.Extra as MX
import Page as P
import Page.App.Placeholder as Placeholder
import String.Extra as SX
import Task
import Time exposing (Posix)
import Time.Extra as TX
import Url.Builder as UB
import Util as U



-- MODEL


type alias Mdl =
    { user : User
    , input : String
    , caret : Int
    , msg : String
    , msgFix : Bool
    , items : List Item
    , selected : List Tid
    , cursor : Index
    , view : View
    , timescale : U.Timescale
    , now : Posix
    , asOf : Posix
    , isCurrent : Bool
    , isInput : Bool
    , isInputFS : Bool
    , keyMod : KeyMod
    , isDeleting : Bool
    , deleting : List Tid
    , token : Maybe String
    }


type alias User =
    { name : String
    , zone : Time.Zone
    , timescale : U.Timescale
    , allocations : List U.Allocation
    }


type alias Index =
    Int


type alias Tid =
    Int


type View
    = None
    | Home_
    | Leaves
    | Roots
    | Archives
    | Focus_
    | Search


type alias KeyMod =
    { ctrl : Bool
    , shift : Bool
    }


init : Bool -> User -> ( Mdl, Cmd Msg )
init isDemo user =
    ( { user = user
      , input = ""
      , caret = 0
      , msg = [ "Hello", user.name ] |> String.join " "
      , msgFix = True
      , items = []
      , selected = []
      , cursor = 0
      , view = None
      , timescale = user.timescale
      , now = Time.millisToPosix 0
      , asOf = Time.millisToPosix 0
      , isCurrent = True
      , isInput = False
      , isInputFS = False
      , keyMod = KeyMod False False
      , isDeleting = False
      , deleting = []
      , token = Nothing
      }
    , isDemo |> BX.ifElse (Text "/tutorial") (Home Nothing) |> request
    )



-- UPDATE


type Msg
    = Goto P.Page
    | NoOp
    | Tick Posix
    | NewTab Url
    | SetCaret Int
    | FromU FromU
    | FromS FromS


type FromU
    = Request Req
    | Input String
    | InputBlur
    | InputFocus
    | KeyDown Key
    | KeyUp Key
    | Select Tid


type FromS
    = LoggedOut U.HttpResultAny
    | Homed (Maybe String) (U.HttpResult ResHome)
    | Texted (U.HttpResult ResText)
    | Execed Bool (U.HttpResult ResExec)
    | Deleted (List Tid) (U.HttpResult ResDelete)
    | Focused Item (U.HttpResult ResFocus)
    | Starred Tid U.HttpResultAny
    | IndentHere Int


update : Msg -> Mdl -> ( Mdl, Cmd Msg )
update msg mdl =
    case msg of
        Goto _ ->
            ( mdl, Cmd.none )

        NoOp ->
            ( mdl, Cmd.none )

        Tick now ->
            ( { mdl
                | now = now
                , asOf = mdl.isCurrent |> BX.ifElse now mdl.asOf
              }
            , Cmd.none
            )

        NewTab _ ->
            ( mdl, Cmd.none )

        SetCaret _ ->
            ( mdl, Cmd.none )

        FromU fromU ->
            case fromU of
                Request req ->
                    ( mdl, request req )

                Input s ->
                    ( { mdl | input = s }, Cmd.none )

                InputBlur ->
                    ( { mdl | isInput = False }, Cmd.none )

                InputFocus ->
                    ( { mdl | isInput = True }, Cmd.none )

                KeyDown key ->
                    if mdl.isDeleting then
                        let
                            cleared =
                                { mdl | isDeleting = False, deleting = [], token = Nothing }
                        in
                        case key of
                            Char 'y' ->
                                ( cleared
                                , Delete { tids = mdl.deleting, token = mdl.token } |> request
                                )

                            _ ->
                                ( { cleared | msg = "Deletion cancelled." }, Cmd.none )

                    else
                        case key of
                            Char c ->
                                if mdl.isInput then
                                    ( mdl, Cmd.none )

                                else
                                    case c of
                                        '/' ->
                                            ( mdl, U.idBy "app" "input" |> Dom.focus |> Task.attempt (\_ -> NoOp) )

                                        'q' ->
                                            ( { mdl | timescale = mdl.timescale |> U.scale -1 }, Cmd.none )

                                        'p' ->
                                            ( { mdl | timescale = mdl.timescale |> U.scale 1 }, Cmd.none )

                                        'w' ->
                                            ( { mdl | asOf = mdl.asOf |> timeshift mdl -1, isCurrent = False }, Cmd.none )

                                        'o' ->
                                            ( { mdl | asOf = mdl.asOf |> timeshift mdl 1, isCurrent = False }, Cmd.none )

                                        'j' ->
                                            ( { mdl | cursor = mdl.cursor < List.length mdl.items - 1 |> BX.ifElse (mdl.cursor + 1) mdl.cursor }, follow Down mdl )

                                        'k' ->
                                            ( { mdl | cursor = 0 < mdl.cursor |> BX.ifElse (mdl.cursor - 1) mdl.cursor }, follow Up mdl )

                                        'x' ->
                                            ( mdl, forTheItem mdl (\item -> Select item.id |> U.cmd FromU) )

                                        'u' ->
                                            ( mdl, forTheItem mdl (\item -> item.link |> MX.unwrap NoOp (\url -> NewTab url) |> U.cmd identity) )

                                        'i' ->
                                            ( { mdl | selected = mdl.items |> List.filter (\item -> LX.notMember item.id mdl.selected) |> List.map .id }, Cmd.none )

                                        's' ->
                                            ( mdl, forTheItem mdl (\item -> Star item.id |> request) )

                                        'f' ->
                                            ( mdl, forTheItem mdl (\item -> Focus item |> request) )

                                        'e' ->
                                            ( mdl, Exec { tids = mdl.selected, revert = mdl.keyMod.shift } |> request )

                                        'v' ->
                                            ( mdl, Exec { tids = mdl.selected, revert = True } |> request )

                                        'c' ->
                                            ( { mdl
                                                | input = mdl.selected |> clone mdl
                                                , msg =
                                                    [ "Cloned"
                                                    , mdl.selected |> List.length |> U.int
                                                    ]
                                                        |> String.join " "
                                              }
                                            , U.idBy "app" "input" |> Dom.focus |> Task.attempt (\_ -> NoOp)
                                            )

                                        'd' ->
                                            ( mdl, Delete { tids = mdl.selected, token = Nothing } |> request )

                                        'a' ->
                                            ( mdl, Home (Just "archives") |> request )

                                        'r' ->
                                            ( mdl, Home (Just "roots") |> request )

                                        'l' ->
                                            ( mdl, Home (Just "leaves") |> request )

                                        'h' ->
                                            ( mdl, Home Nothing |> request )

                                        _ ->
                                            ( mdl, Cmd.none )

                            NonChar nc ->
                                case nc of
                                    Modifier m ->
                                        ( { mdl | keyMod = mdl.keyMod |> setKeyMod m True }, Cmd.none )

                                    Enter ->
                                        mdl.keyMod.ctrl
                                            |> BX.ifElse
                                                ( { mdl | isInputFS = False }, Text mdl.input |> request )
                                                ( mdl, Cmd.none )

                                    ArrowDown ->
                                        ( mdl.keyMod.ctrl |> BX.ifElse { mdl | isInputFS = True } mdl, Cmd.none )

                                    ArrowUp ->
                                        ( mdl.keyMod.ctrl |> BX.ifElse { mdl | isInputFS = False } mdl, Cmd.none )

                                    Escape ->
                                        ( mdl, U.idBy "app" "input" |> Dom.blur |> Task.attempt (\_ -> NoOp) )

                            AnyKey ->
                                ( mdl, Cmd.none )

                KeyUp key ->
                    case key of
                        Char _ ->
                            ( mdl, Cmd.none )

                        NonChar nc ->
                            case nc of
                                Modifier m ->
                                    ( { mdl | keyMod = mdl.keyMod |> setKeyMod m False }, Cmd.none )

                                _ ->
                                    ( mdl, Cmd.none )

                        AnyKey ->
                            ( mdl, Cmd.none )

                Select tid ->
                    ( { mdl | selected = mdl.selected |> (\l -> List.member tid l |> BX.ifElse (LX.remove tid l) (tid :: l)) }, Cmd.none )

        FromS fromS ->
            case fromS of
                LoggedOut (Ok _) ->
                    ( mdl, U.cmd Goto P.LP )

                Homed option (Ok ( _, res )) ->
                    let
                        view_ =
                            [ "leaves"
                            , "roots"
                            , "archives"
                            ]
                                |> List.map (\s -> option == Just s)
                                |> U.overwrite Home_ [ Leaves, Roots, Archives ]
                    in
                    ( { mdl
                        | msg =
                            mdl.msgFix
                                |> BX.ifElse mdl.msg
                                    (res
                                        |> List.isEmpty
                                        |> (&&) (view_ == Home_)
                                        |> BX.ifElse "Nothing to execute, working tree clean."
                                            ([ option |> MX.unwrap False ((==) "archives") |> BX.ifElse "Last" ""
                                             , res |> List.length |> singularize (option |> Maybe.withDefault "items")
                                             , "here."
                                             ]
                                                |> String.join " "
                                            )
                                    )
                        , msgFix = False
                        , items = res
                        , selected = []
                        , cursor = 0
                        , view = view_
                        , timescale = mdl.user.timescale
                        , isCurrent = True
                      }
                    , Cmd.none
                    )

                Texted (Ok ( _, res )) ->
                    case res of
                        ResTextC (ResHelp s) ->
                            ( { mdl | input = s }, Cmd.none )

                        ResTextC (ResUser (ResHelpU s)) ->
                            ( { mdl | input = s }, Cmd.none )

                        ResTextC (ResUser (ResInfo_ r)) ->
                            let
                                section =
                                    \s ss ->
                                        (s :: ss) |> String.join "\n"
                            in
                            ( { mdl
                                | input =
                                    [ "<!-- USER INFO"
                                    , section "## NAME" [ mdl.user.name ]
                                    , section "## EMAIL" [ r.email ]
                                    , section "## SINCE" [ U.clock False mdl.user.zone r.since ]
                                    , section "## EXECUTED" [ U.int r.executed ]
                                    , section "## TIMEZONE" [ r.tz ]
                                    , section "## ALLOCATIONS" (mdl.user.allocations |> List.map U.strAllocation)
                                    , section "## PERMISSIONS" []
                                    , section "VIEW ==>" r.permissions.view_to
                                    , section "EDIT ==>" r.permissions.edit_to
                                    , section "<== VIEW" r.permissions.view_from
                                    , section "<== EDIT" r.permissions.edit_from
                                    , section "## PRESS [Ctrl]+[Enter] TO EXIT -->" []
                                    ]
                                        |> String.join "\n\n"
                                , isInputFS = True
                              }
                            , Cmd.none
                            )

                        ResTextC (ResUser (ResModify m)) ->
                            (case m of
                                Email s ->
                                    ( { mdl | msg = "Email: " ++ s }, Cmd.none )

                                Password _ ->
                                    ( { mdl | msg = "Password modified." }, Cmd.none )

                                Name s ->
                                    ( { mdl
                                        | user =
                                            let
                                                user =
                                                    mdl.user
                                            in
                                            { user | name = s }
                                        , msg = "User Name: " ++ s
                                        , msgFix = True
                                      }
                                    , Home Nothing |> request
                                    )

                                Timescale s ->
                                    ( { mdl
                                        | user =
                                            let
                                                user =
                                                    mdl.user
                                            in
                                            { user | timescale = U.timescale s }
                                        , msg = "Time Scale: " ++ s
                                        , timescale = U.timescale s
                                      }
                                    , Cmd.none
                                    )

                                Allocations alcs ->
                                    ( { mdl
                                        | user =
                                            let
                                                user =
                                                    mdl.user
                                            in
                                            { user | allocations = alcs }
                                        , msg =
                                            "Time Allocations: "
                                                ++ (alcs
                                                        |> List.map U.strAllocation
                                                        |> String.join ", "
                                                   )
                                        , msgFix = True
                                      }
                                    , Home Nothing |> request
                                    )

                                Permission r ->
                                    ( { mdl
                                        | msg =
                                            [ mdl.user.name
                                            , "<==(allow"
                                            , (case r.permission of
                                                Just edit ->
                                                    edit |> BX.ifElse "EDIT" "VIEW"

                                                _ ->
                                                    "NONE"
                                              )
                                                ++ ")=="
                                            , r.user
                                            ]
                                                |> String.join " "
                                        , msgFix = True
                                      }
                                    , Home Nothing |> request
                                    )
                            )
                                |> input0

                        ResTextC (ResSearch (ResHelpS s)) ->
                            ( { mdl | input = s }, Cmd.none )

                        ResTextC (ResSearch (ResCondition items)) ->
                            ( { mdl
                                | msg = items |> List.length |> singularize "search results"
                                , items = items
                                , selected = []
                                , cursor = 0
                                , view = Search
                              }
                            , inputBlur
                            )

                        ResTextC (ResTutorial s) ->
                            ( { mdl | input = s }, Cmd.none )

                        ResTextT_ r ->
                            ( { mdl
                                | msg =
                                    [ "Created"
                                    , r.created |> U.int
                                    , "/"
                                    , "Updated"
                                    , r.updated |> U.int
                                    ]
                                        |> String.join " "
                                , msgFix = True
                              }
                            , Home Nothing |> request
                            )
                                |> input0

                Execed revert (Ok ( _, res )) ->
                    ( { mdl
                        | msg =
                            [ revert |> BX.ifElse "Reverted" "Executed"
                            , res.count |> U.int
                            , "("
                            , "Chained"
                            , res.chain |> U.int
                            , ")"
                            ]
                                |> String.join " "
                        , msgFix = True
                        , cursor = 0
                      }
                    , Home Nothing |> request
                    )

                Deleted tids (Ok ( meta, res )) ->
                    case meta.statusCode of
                        202 ->
                            ( { mdl
                                | msg =
                                    [ "Deleting"
                                    , (tids |> List.length |> singularize "items") ++ "."
                                    , "Are you sure?"
                                    , "y/N"
                                    ]
                                        |> String.join " "
                                , isDeleting = True
                                , deleting = tids
                                , token = res
                              }
                            , Cmd.none
                            )

                        200 ->
                            ( { mdl
                                | msg =
                                    [ "Deleted"
                                    , tids |> List.length |> U.int
                                    ]
                                        |> String.join " "
                                , msgFix = True
                                , cursor = 0
                              }
                            , Home Nothing |> request
                            )

                        _ ->
                            ( mdl, Cmd.none )

                Focused item (Ok ( _, res )) ->
                    ( { mdl
                        | msg =
                            [ "#" ++ U.int item.id
                            , "Pred." ++ U.len res.pred
                            , "Succ." ++ U.len res.succ
                            ]
                                |> String.join " "
                        , items = res.pred ++ ({ item | schedule = Nothing, priority = Nothing } :: res.succ)
                        , selected = []
                        , cursor = List.length res.pred
                        , view = Focus_
                      }
                    , Cmd.none
                    )

                Starred tid (Ok _) ->
                    ( { mdl | items = mdl.items |> LX.updateIf (\item -> item.id == tid) (\item -> { item | isStarred = not item.isStarred }) }
                    , Cmd.none
                    )

                LoggedOut (Err e) ->
                    handle mdl e

                Homed _ (Err e) ->
                    handle mdl e

                Texted (Err e) ->
                    handle mdl e

                Execed _ (Err e) ->
                    handle mdl e

                Deleted _ (Err e) ->
                    handle mdl e

                Focused _ (Err e) ->
                    handle mdl e

                Starred _ (Err e) ->
                    handle mdl e

                IndentHere i ->
                    let
                        alterLineBy : (String -> String) -> String -> String
                        alterLineBy f =
                            SX.break i
                                >> LX.updateAt 0
                                    (String.lines
                                        >> LX.unconsLast
                                        >> MX.unwrap []
                                            (\( l, ls ) ->
                                                ls ++ (f l |> List.singleton)
                                            )
                                        >> String.join "\n"
                                    )
                                >> String.concat

                        f_ =
                            mdl.keyMod.shift
                                |> BX.ifElse
                                    (\s -> s |> String.startsWith Config.indent |> BX.ifElse (s |> SX.rightOf Config.indent) s)
                                    ((++) Config.indent)

                        newInput =
                            mdl.input |> alterLineBy f_

                        diff =
                            String.length newInput - String.length mdl.input
                    in
                    ( { mdl | input = newInput }
                    , SetCaret (i + diff) |> U.cmd identity
                    )


handle : Mdl -> U.HttpError -> ( Mdl, Cmd Msg )
handle mdl e =
    case U.errCode e of
        -- Unauthorized
        Just 401 ->
            ( mdl, request Logout )

        _ ->
            ( { mdl | msg = U.strHttpError e }, Cmd.none )


type DU
    = Down
    | Up


follow : DU -> Mdl -> Cmd Msg
follow du mdl =
    let
        h =
            itemHeight |> toFloat

        cursorY =
            mdl.cursor |> toFloat |> (*) h

        theId =
            U.idBy "app" "items"
    in
    Dom.getViewportOf theId
        |> Task.andThen
            (\info ->
                let
                    top =
                        info.viewport.y

                    bottom =
                        top + info.viewport.height

                    setAtCursor =
                        \adjust condition ->
                            condition
                                |> BX.ifElse
                                    (Dom.setViewportOf theId 0 (cursorY - (info.viewport.height / 2) + adjust))
                                    (Dom.blur "")
                in
                case du of
                    Down ->
                        bottom - 3 * h < cursorY |> setAtCursor (2 * h)

                    Up ->
                        cursorY < top + h |> setAtCursor 0
            )
        |> Task.attempt (\_ -> NoOp)


forTheItem : Mdl -> (Item -> Cmd msg) -> Cmd msg
forTheItem mdl f =
    mdl.items |> LX.getAt mdl.cursor |> MX.unwrap Cmd.none f


setKeyMod : Modifier -> Bool -> KeyMod -> KeyMod
setKeyMod m b mod =
    case m of
        Control ->
            { mod | ctrl = b }

        Shift ->
            { mod | shift = b }


input0 : ( Mdl, Cmd Msg ) -> ( Mdl, Cmd Msg )
input0 ( mdl, cmd ) =
    ( { mdl | input = "" }, Cmd.batch [ cmd, inputBlur ] )


inputBlur : Cmd Msg
inputBlur =
    U.idBy "app" "input" |> Dom.blur |> Task.attempt (\_ -> NoOp)


singularize : String -> Int -> String
singularize plural i =
    [ ( "items", "item" )
    , ( "leaves", "leaf" )
    , ( "roots", "root" )
    , ( "archives", "archive" )
    , ( "search results", "search result" )
    ]
        |> LX.find (\( p, _ ) -> p == plural)
        |> MX.unwrap plural (\( p, s ) -> SX.pluralize s p i)


clone : Mdl -> List Tid -> String
clone mdl ids =
    let
        cloneBy : Time.Zone -> Item -> String
        cloneBy zone item =
            [ [ item.id |> (\id -> "#" ++ U.int id)
              , item.isStarred |> BX.ifElse "*" ""
              , item.title
              , item.startable |> MX.unwrap "" (\t -> U.clock True zone t ++ "-")
              , item.deadline |> MX.unwrap "" (\t -> "-" ++ U.clock True zone t)
              , item.weight |> MX.unwrap "" (\w -> "$" ++ String.fromFloat w)
              , item.assign |> (++) "@"
              ]
                |> List.filter (String.isEmpty >> not)
                |> String.join " "
            , item.link |> Maybe.withDefault ""
            ]
                |> List.filter (String.isEmpty >> not)
                |> String.join "\n"
    in
    mdl.items
        |> List.filter (\item -> List.member item.id ids)
        |> List.map (cloneBy mdl.user.zone)
        |> String.join "\n"



-- VIEW


itemHeight : Int
itemHeight =
    32


imgDir : String
imgDir =
    "images"


view : Mdl -> Html Msg
view mdl =
    let
        block =
            "app"

        idBy =
            \elem -> U.idBy block elem |> Html.Attributes.id

        bem =
            U.bem block

        img_ =
            \alt_ basename -> img [ alt alt_, UB.relative [ imgDir, basename ++ ".png" ] [] |> src ] []

        toCharBtn =
            \cl mod ->
                let
                    char =
                        mod |> U.unconsOr ' '
                in
                button
                    [ bem "btn" []
                    , classList cl
                    , KeyDown (Char char) |> onClick
                    ]
                    [ img_ mod ("cmd_" ++ String.fromChar char) ]

        toEditBtn =
            toCharBtn []

        toViewBtn =
            \mod -> toCharBtn [ ( "on", mod |> asView |> MX.unwrap False (\v -> v == mdl.view) ) ] mod

        item__ =
            \elem -> U.bem "item" elem [ ( "header", True ) ]
    in
    div [ bem "" [] ]
        [ header [ bem "header" [] ]
            [ div [ bem "logos" [] ]
                [ div [ bem "logo" [] ] [ img_ "logo" "logo" ] ]
            , div [ bem "inputs" [] ]
                [ textarea
                    [ idBy "input"
                    , bem "input" [ ( "fullscreen", mdl.isInputFS ) ]
                    , value mdl.input
                    , onInput Input
                    , onFocus InputFocus
                    , onBlur InputBlur
                    , placeholder Placeholder.placeholder
                    , spellcheck True
                    ]
                    []
                ]
            , div [ bem "sends" [] ]
                [ button [ bem "btn" [ ( "send", True ) ], Request (Text mdl.input) |> onClick ] [ img_ "send" "sprig" ] ]
            , div [ bem "accounts" [] ]
                [ button [ bem "btn" [ ( "account", True ) ], Request Logout |> onClick ] [ span [] [ text mdl.user.name ] ] ]
            ]
        , div [ bem "body" [] ]
            [ div [ bem "sidebar" [] ]
                [ ul [ bem "icons" [] ]
                    ([ ( "timescale", "qp" )
                     , ( "timeshift", "wo" )
                     , ( "updown", "jk" )
                     , ( "select", "x" )
                     , ( "star", "s" )
                     , ( "focus", "f" )
                     , ( "url", "u" )
                     ]
                        |> List.map (\( mod, key ) -> li [ bem "icon" [] ] [ img_ mod ("cmd_" ++ key) ])
                    )
                ]
            , main_ [ bem "main" [] ]
                [ nav [ bem "nav" [] ]
                    [ div [ bem "btns" [ ( "edit", True ) ] ]
                        ([ "invert", "exec", "clone" ] |> List.map toEditBtn)
                    , div [ bem "msg" [] ] [ span [] [ text mdl.msg ] ]
                    , div [ bem "btns" [ ( "view", True ) ] ]
                        ([ "archives", "roots", "leaves", "home" ] |> List.map toViewBtn)
                    , div [ bem "scroll" [] ] []
                    ]
                , table [ bem "table" [] ]
                    [ thead [ bem "table-header" [] ]
                        [ th [ item__ "cursor" ] []
                        , th [ item__ "select" ] [ U.len1 mdl.selected |> text ]
                        , th [ item__ "star" ] []
                        , th [ item__ "title" ] []
                        , th [ item__ "startable" ] [ U.strTimescale mdl.timescale |> text ]
                        , th [ item__ "bar" ] [ span [] [ "As of " ++ U.clock False mdl.user.zone mdl.asOf |> text ] ]
                        , th [ item__ "deadline" ] [ U.fmtDT mdl.timescale |> text ]
                        , th [ item__ "priority" ] []
                        , th [ item__ "weight" ] []
                        , th [ item__ "assign" ] []
                        , th [ bem "scroll" [] ] []
                        ]
                    , U.enumerate mdl.items
                        |> List.map (viewItem mdl)
                        |> tbody [ idBy "items", bem "items" [] ]
                    ]
                ]
            , div [ bem "sidebar" [ ( "pad-scroll", True ) ] ] []
            ]
        , footer [ bem "footer" [] ] []
        ]
        -- disable click while deleting
        |> Html.map (mdl.isDeleting |> BX.ifElse (\_ -> NoOp) FromU)


asView : String -> Maybe View
asView s =
    [ "home"
    , "leaves"
    , "roots"
    , "archives"
    , "focus"
    , "search"
    ]
        |> List.map ((==) s)
        |> U.overwrite Nothing
            ([ Home_
             , Leaves
             , Roots
             , Archives
             , Focus_
             , Search
             ]
                |> List.map Just
            )


viewItem : Mdl -> ( Index, Item ) -> Html FromU
viewItem mdl ( idx, item ) =
    let
        bem =
            U.bem "item"

        isSelected =
            List.member item.id mdl.selected
    in
    tr
        [ Html.Attributes.style "height" (U.int itemHeight ++ "px")
        , bem "" [ ( "selected", isSelected ) ]
        ]
        [ td [ bem "cursor" [ ( "spot", idx == mdl.cursor ) ] ] []
        , td [ bem "select" [], Select item.id |> onClick ] [ isSelected |> BX.ifElse "+" "-" |> text ]
        , td [ bem "star" [], Request (Star item.id) |> onClick ] [ item.isStarred |> BX.ifElse "★" "☆" |> text ]
        , td [ bem "title" [] ] [ span [] [ item.title |> text |> (\t -> item.link |> MX.unwrap t (\l -> a [ href l, target "_blank" ] [ t ])) ] ]
        , td [ bem "startable" [] ] [ item.startable |> MX.unwrap "-" (U.strDT mdl.timescale mdl.user.zone) |> text ]
        , td
            [ bem "bar" []
            , Request (Focus item) |> onClick
            , property "schedule" (item.schedule |> encSchedule mdl.user.zone)
            ]
            [ item |> dotString mdl |> text ]
        , td
            [ bem "deadline" [ ( "overdue", item |> isOverdue mdl ) ] ]
            [ item.deadline |> MX.unwrap "-" (U.strDT mdl.timescale mdl.user.zone) |> text ]
        , td
            [ bem "priority" [ ( "high", 0 < (item.priority |> Maybe.withDefault 0) ) ] ]
            [ item.isArchived |> BX.ifElse "X" (item.priority |> MX.unwrap "-" strPriority) |> text ]
        , td [ bem "weight" [] ] [ item.weight |> MX.unwrap "-" strWeight |> text ]
        , td [ bem "assign" [] ] [ span [] [ item.assign == mdl.user.name |> BX.ifElse "me" item.assign |> text ] ]
        ]


strPriority : Float -> String
strPriority x =
    [ not (-1000 < x), not (x < 1000) ] |> U.overwrite (U.signedDecimal 1 x) [ "low", "high" ]


strWeight : Float -> String
strWeight x =
    [ not (x < 10000) ] |> U.overwrite (U.decimal 1 x) [ "heavy" ]


isOverdue : Mdl -> Item -> Bool
isOverdue mdl item =
    let
        isOverDeadline =
            item.deadline |> MX.unwrap False (\d -> d |> U.lt mdl.now)
    in
    not item.isArchived && isOverDeadline


timeshift : Mdl -> Int -> Posix -> Posix
timeshift mdl i =
    TX.add mdl.timescale.interval (i * mdl.timescale.multiple) mdl.user.zone


dotString : Mdl -> Item -> String
dotString mdl item =
    let
        inc =
            timeshift mdl 1
    in
    List.range 0 51
        |> List.map
            (\i ->
                let
                    l =
                        mdl.asOf |> U.apply i inc

                    r =
                        inc l
                in
                dot
                    (Dotter
                        l
                        r
                        mdl.user.zone
                        mdl.timescale
                        mdl.user.allocations
                    )
                    item
            )
        |> String.fromList


type alias Dotter =
    { l : Posix
    , r : Posix
    , zone : Time.Zone
    , scale : U.Timescale
    , allocations : List U.Allocation
    }


dot : Dotter -> Item -> Char
dot dotter item =
    let
        hasDeadline =
            item.deadline |> MX.unwrap False (U.between dotter.l dotter.r)

        hasStartable =
            item.startable |> MX.unwrap False (U.between dotter.l dotter.r)

        hasSchedule =
            item.schedule
                |> MX.unwrap False
                    (\sch -> ( sch.l, sch.r ) |> U.intersect ( dotter.l, dotter.r ))

        hasAllocation =
            let
                parts =
                    dotter.l |> TX.posixToParts dotter.zone

                allocations =
                    List.range -1 1
                        |> List.concatMap
                            (\i ->
                                dotter.allocations
                                    |> List.map
                                        (\alc ->
                                            let
                                                open =
                                                    { parts | hour = alc.open_h, minute = alc.open_m }
                                                        |> TX.partsToPosix dotter.zone
                                                        |> TX.add TX.Day i dotter.zone

                                                close =
                                                    open |> TX.add TX.Hour alc.hours dotter.zone
                                            in
                                            ( open, close )
                                        )
                            )
            in
            allocations |> List.any (U.intersect ( dotter.l, dotter.r ))

        hasBoundary =
            U.scales
                |> LX.zip
                    [ \t -> Time.toYear dotter.zone t |> remainderBy 10 |> (==) 0
                    , \t -> List.member (Time.toMonth dotter.zone t) [ Time.Apr, Time.May, Time.Jun ]
                    , \t -> List.member (Time.toMonth dotter.zone t) [ Time.Apr, Time.Jul, Time.Oct, Time.Jan ]
                    , \t -> List.member (Time.toDay dotter.zone t) (List.range 1 7)
                    , \t -> Time.toWeekday dotter.zone t == Time.Sun
                    , \t -> List.member (Time.toHour dotter.zone t) (List.range 0 5)
                    , \t -> List.member (Time.toHour dotter.zone t) [ 0, 6, 12, 18 ]
                    , \t -> List.member (Time.toMinute dotter.zone t) (List.range 0 14)
                    , \t -> List.member (Time.toMinute dotter.zone t) [ 0, 15, 30, 45 ]
                    , \t -> Time.toSecond dotter.zone t |> (==) 0
                    ]
                |> LX.find (\( _, scl ) -> scl == dotter.scale)
                |> MX.unwrap False (\( cnd, _ ) -> dotter.r |> cnd)
    in
    U.overwrite '.'
        [ ':', '#', '[', ']' ]
        [ hasBoundary, hasSchedule && hasAllocation, hasStartable, hasDeadline ]



-- SUBSCRIPTIONS


subscriptions : Mdl -> Sub Msg
subscriptions _ =
    Sub.batch
        [ Time.every 1000 Tick
        , decKey |> Decode.map (KeyDown >> FromU) |> Events.onKeyDown
        , decKey |> Decode.map (KeyUp >> FromU) |> Events.onKeyUp
        ]


decKey : Decoder Key
decKey =
    Decode.field "key" Decode.string
        |> Decode.map
            (\s ->
                case String.uncons s of
                    Just ( c, "" ) ->
                        Char c

                    _ ->
                        case s of
                            "Control" ->
                                Modifier Control |> NonChar

                            "Shift" ->
                                Modifier Shift |> NonChar

                            "Enter" ->
                                NonChar Enter

                            "ArrowDown" ->
                                NonChar ArrowDown

                            "ArrowUp" ->
                                NonChar ArrowUp

                            "Escape" ->
                                NonChar Escape

                            _ ->
                                AnyKey
            )


type Key
    = Char Char
    | NonChar NonChar
    | AnyKey


type NonChar
    = Modifier Modifier
    | Enter
    | ArrowDown
    | ArrowUp
    | Escape


type Modifier
    = Control
    | Shift



-- INTERFACE


type Req
    = Logout
    | Home (Maybe String)
    | Text String
    | Exec { tids : List Tid, revert : Bool }
    | Delete { tids : List Tid, token : Maybe String }
    | Focus Item
    | Star Tid


request : Req -> Cmd Msg
request req =
    case req of
        Logout ->
            U.delete_ EP.Auth (FromS << LoggedOut)

        Home option ->
            let
                query =
                    case option of
                        Just s ->
                            [ UB.string "option" s ]

                        _ ->
                            []
            in
            U.get (EP.Tasks |> EP.App_) query (FromS << Homed option) decHome

        Text text ->
            let
                json =
                    Encode.object
                        [ ( "text", Encode.string text ) ]
            in
            U.post (EP.Tasks |> EP.App_) json (FromS << Texted) decText

        Exec { tids, revert } ->
            let
                json =
                    Encode.object
                        [ ( "tasks", Encode.list Encode.int tids )
                        , ( "revert", Encode.bool revert )
                        ]
            in
            U.put (EP.Tasks |> EP.App_) json (FromS << Execed revert) decExec

        Delete { tids, token } ->
            let
                json =
                    Encode.object
                        [ ( "tasks", Encode.list Encode.int tids )
                        , ( "token", token |> MX.unwrap Encode.null Encode.string )
                        ]
            in
            U.delete (EP.Tasks |> EP.App_) json (FromS << Deleted tids) decDelete

        Focus item ->
            U.get (EP.Task item.id |> EP.App_) [] (FromS << Focused item) decFocus

        Star tid ->
            U.put_ (EP.Task tid |> EP.App_) (FromS << Starred tid)



-- request home


type alias ResHome =
    List Item


decHome : Decoder ResHome
decHome =
    Decode.field "tasks" (list decItem)



-- request text


type ResText
    = ResTextC ResTextC
    | ResTextT_ ResTextT


type alias ResTextT =
    { created : Int
    , updated : Int
    }


type ResTextC
    = ResHelp String
    | ResUser ResUser
    | ResSearch ResSearch
    | ResTutorial String


type ResUser
    = ResHelpU String
    | ResInfo_ ResInfo
    | ResModify ResModify


type alias ResInfo =
    { email : String
    , since : Posix
    , executed : Int
    , tz : String
    , permissions : ResPermissions
    }


type alias ResPermissions =
    { view_to : List String
    , edit_to : List String
    , view_from : List String
    , edit_from : List String
    }


type ResModify
    = Email String
    | Password ()
    | Name String
    | Timescale String
    | Allocations (List U.Allocation)
    | Permission ResPermission


type alias ResPermission =
    { user : String
    , permission : Maybe Bool
    }


type ResSearch
    = ResHelpS String
    | ResCondition (List Item)


decText : Decoder ResText
decText =
    oneOf
        [ Decode.succeed ResTextC
            |> required "Cmd"
                (oneOf
                    [ Decode.succeed ResHelp
                        |> required "Help" string
                    , Decode.succeed ResUser
                        |> required "User"
                            (oneOf
                                [ Decode.succeed ResHelpU
                                    |> required "Help" string
                                , Decode.succeed ResInfo_
                                    |> required "Info"
                                        (Decode.succeed ResInfo
                                            |> required "email" string
                                            |> required "since" datetime
                                            |> required "executed" int
                                            |> required "tz" string
                                            |> required "permissions" decPermissions
                                        )
                                , Decode.succeed ResModify
                                    |> required "Modify"
                                        (oneOf
                                            [ Decode.succeed Email
                                                |> required "Email" string
                                            , Decode.succeed Password
                                                |> required "Password" (null ())
                                            , Decode.succeed Name
                                                |> required "Name" string
                                            , Decode.succeed Timescale
                                                |> required "Timescale" string
                                            , Decode.succeed Allocations
                                                |> required "Allocations" (list U.decAllocation)
                                            , Decode.succeed Permission
                                                |> required "Permission" decPermission
                                            ]
                                        )
                                ]
                            )
                    , Decode.succeed ResSearch
                        |> required "Search"
                            (oneOf
                                [ Decode.succeed ResHelpS
                                    |> required "Help" string
                                , Decode.succeed ResCondition
                                    |> required "Condition" (list decItem)
                                ]
                            )
                    , Decode.succeed ResTutorial
                        |> required "Tutorial" string
                    ]
                )
        , Decode.succeed ResTextT
            |> requiredAt [ "Tasks", "created" ] int
            |> requiredAt [ "Tasks", "updated" ] int
            |> Decode.map ResTextT_
        ]


decPermissions : Decoder ResPermissions
decPermissions =
    Decode.succeed ResPermissions
        |> required "view_to" (list string)
        |> required "edit_to" (list string)
        |> required "view_from" (list string)
        |> required "edit_from" (list string)


decPermission : Decoder ResPermission
decPermission =
    Decode.succeed ResPermission
        |> required "user" string
        |> required "permission" (nullable bool)



-- request exec


type alias ResExec =
    { count : Int
    , chain : Int
    }


decExec : Decoder ResExec
decExec =
    Decode.succeed ResExec
        |> required "count" int
        |> required "chain" int



-- request exec


type alias ResDelete =
    Maybe String


decDelete : Decoder ResDelete
decDelete =
    Decode.field "token" (nullable string)



-- request focus


type alias ResFocus =
    { pred : List Item
    , succ : List Item
    }


decFocus : Decoder ResFocus
decFocus =
    Decode.succeed ResFocus
        |> required "pred" (list decItem)
        |> required "succ" (list decItem)



-- request


type alias Item =
    { id : Tid
    , title : String
    , assign : String
    , isArchived : Bool
    , isStarred : Bool
    , startable : Maybe Posix
    , deadline : Maybe Posix
    , priority : Maybe Float
    , weight : Maybe Float
    , link : Maybe Url
    , schedule : Maybe Schedule
    }


type alias Url =
    String


type alias Schedule =
    { l : Posix
    , r : Posix
    }


decItem : Decoder Item
decItem =
    Decode.succeed Item
        |> required "id" int
        |> required "title" string
        |> required "assign" string
        |> required "is_archived" bool
        |> required "is_starred" bool
        |> required "startable" (nullable datetime)
        |> required "deadline" (nullable datetime)
        |> required "priority" (nullable float)
        |> required "weight" (nullable float)
        |> required "link" (nullable string)
        |> required "schedule" (nullable decSchedule)


decSchedule : Decoder Schedule
decSchedule =
    Decode.succeed Schedule
        |> required "l" datetime
        |> required "r" datetime


encSchedule : Time.Zone -> Maybe Schedule -> Encode.Value
encSchedule zone =
    EX.maybe
        (\sch ->
            Encode.object
                [ ( "l", Encode.string (sch.l |> U.clock True zone) )
                , ( "r", Encode.string (sch.r |> U.clock True zone) )
                ]
        )
