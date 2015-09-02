module Main where

-- ulimit -n 2560
-- pulp browserify > dist/app.js

import Prelude

import Control.Bind ((=<<))
import Control.Alt ((<|>))
import Control.Plus (empty)
import Control.Apply ((*>))
import Control.Monad.Aff (Aff(), launchAff, later')
import Control.Monad.Eff (Eff())
import Control.Monad.Eff.Console (print)
import Control.Monad.Free (liftFI)
import Data.Foldable (foldr)
import Data.Traversable (for)
import Math (abs, round, pow)
import Data.Int (toNumber, fromNumber)
import Data.Array
import Data.Maybe (Maybe(..), maybe)
import Data.Either
import Data.Function (on)
import Data.Tuple (Tuple(..))

import Control.Monad.Eff.Class (MonadEff, liftEff)
import Halogen
import qualified Halogen.Query.StateF as S
import Halogen.Util (appendToBody)
import qualified Halogen.HTML as H
import qualified Halogen.HTML.Events as E
import qualified Halogen.HTML.Properties as P
import DOM (DOM())
import DOM.Event.EventTarget (eventListener, addEventListener)
import DOM.Event.EventTypes (readystatechange, load)
import DOM.Event.Types (Event())
import DOM.HTML (window)
import DOM.HTML.Document (body)
import DOM.HTML.Types (HTMLElement(), htmlElementToNode, windowToEventTarget)

import Network.HTTP.Affjax (AJAX(), get)

import Routing
import Routing.Match
import Routing.Match.Class

import Team
import Player
import Tip
import Standings
import qualified Bootstrap as B


-- Routing

data Route = PlayersRoute | TipsRoute Player

reverseRoute :: Route -> String
reverseRoute PlayersRoute  = "#"
reverseRoute (TipsRoute p) = "#" ++ playerLit p

routing :: Match Route
routing =
  const PlayersRoute <$> lit ""
    <|>
  TipsRoute <$> routingPlayer

routingPlayer :: Match Player
routingPlayer =
  foldr (<|>) empty (map (\p -> const p <$> lit (playerLit p)) allPlayers)

playerLit :: Player -> String
playerLit JanWulf = "janw"
playerLit Jan = "jan"
playerLit JR = "jr"
playerLit Christoph = "christoph"
playerLit Johannes = "johannes"
playerLit Julia = "julia"
playerLit Daniel = "daniel"
playerLit Mirko = "mirko"
playerLit Ulf = "ulf"
playerLit Sandra = "sandra"
playerLit Maike = "maike"
playerLit Nikita = "nikita"
playerLit Henning = "henning"
playerLit Spiegel = "spiegel"


-- Main Application

type AppEffects = HalogenEffects (ajax :: AJAX)

main :: Eff AppEffects Unit
main = launchAff $ do
  app <- runUI ui initialState
  appendToBody app.node
  w <- liftEff window
  liftEff $
    addEventListener
      load
      (eventListener (\_ -> matches routing $ \_ new -> route app.driver new))
      false
      (windowToEventTarget w)
 where
  route driver PlayersRoute  = launchAff (driver (action Overview))
  route driver (TipsRoute p) = launchAff (driver (action (SelectPlayer p)))

type Matchday = Int

data Input a =
    SelectPlayer Player a
  | SelectDay Matchday a
  | Overview a
  | Use Metric a

data State =
    Loading
  | Error String
  | Players Metric (Array Team) (Tuple Matchday Int)
  | Tips Player Metric (Array Team) (Tuple Matchday Int)


initialState :: State
initialState = Loading

initialMetric :: Metric
initialMetric = Manhattan

ui :: forall eff p. Component State Input (Aff AppEffects) p
ui = component render eval
 where
  render :: Render State Input p
  render Loading =
    renderPage [H.h1_ [H.text "Loading Data..."]]
  render (Error text) =
    renderPage [H.text ("An error occurred: " ++ text)]
  render (Players metric standings days) =
    let entries = entriesForStandings metric standings
    in
    renderPage
      [ renderCurrentTable standings
      , renderMetrics metric
      , H.div [P.class_ (H.className "main-content")]
              [ H.div [P.class_ (H.className "bs-example")] [pointsTable entries] ]
      , renderMatchdays days
      ]
  render (Tips player metric standings days) =
    renderPage
      [ renderCurrentTable standings
      , renderMetrics metric
      , H.div [P.class_ (H.className "main-content")]
              [ H.div [ P.class_ (H.className "players-nav") ]
                      [ H.h2_ [H.text (show player)]
                      , H.a [P.href (reverseRoute PlayersRoute)] [H.text "Zur Übersicht"]
                      ]
              , H.div [P.class_ (H.className "bs-example")] [tipTable metric (tipsForPlayer player) standings]
              ]
      , renderMatchdays days
      ]

  eval :: Eval Input State Input (Aff AppEffects)
  eval (Overview next) = do
    s <- S.get
    stateE <- currentState s
    case stateE of
      Left text -> S.modify (\_ -> Error text)
      Right (Triple metric standings days) -> S.modify (\_ -> Players metric standings days)
    pure next
  eval (SelectPlayer player next) = do
    s <- S.get
    stateE <- currentState s
    case stateE of
      Left text   -> S.modify (\_ -> Error text)
      Right (Triple metric standings days) -> S.modify (\_ -> Tips player metric standings days)
    pure next
  eval (SelectDay day next) = do
    tableE <- liftFI (leagueTable (Just day))
    S.modify (case tableE of
                Left text -> const (Error text)
                Right table -> selectDay (standings table))
    pure next
   where
    selectDay standings (Tips p m _ (Tuple _ max))  = Tips p m standings (Tuple day max)
    selectDay standings (Players m _ (Tuple _ max)) = Players m standings (Tuple day max)
    selectDay _ (Error t)        = Error t
    selectDay _ Loading          = Loading
  eval (Use metric next) = do
    S.modify (evalMetric metric)
    pure next

  evalMetric _ Loading = Loading
  evalMetric _ (Error t) = Error t
  evalMetric metric (Tips p _ standings days) = Tips p metric standings days
  evalMetric metric (Players _ standings days) = Players metric standings days

  currentState (Tips _ metric standings days)  = return (Right (Triple metric standings days))
  currentState (Players metric standings days) = return (Right (Triple metric standings days))
  currentState _ = do
    S.modify (\_ -> Loading)
    tableE <- liftFI (leagueTable Nothing)
    return (do
       LeagueTable maxDay sts <- tableE
       return (Triple initialMetric sts (Tuple maxDay maxDay)))

data Triple a b c = Triple a b c

renderPage :: forall p i. Array (H.HTML p i) -> H.HTML p i
renderPage contents =
  H.div [P.class_ (H.className "content")]
    ( H.h1 [P.class_ (H.className "jumbotron")] [H.text "Saison Spektakel 2015/16"]
    : contents )

renderMatchdays :: forall p. Tuple Int Int -> H.HTML p (Input Unit)
renderMatchdays (Tuple day maxDay) =
  H.div [P.class_ (H.className "matchdays")]
        [ B.navPills (map row (range 1 maxDay)) ]
 where
  row day' =
    Tuple (H.a [ E.onClick (E.input_ (SelectDay day')) ] [ H.text (show day') ]) (day==day')

renderMetrics :: forall p. Metric -> H.HTML p (Input Unit)
renderMetrics metric =
  B.navTabs
    [ row "Manhattan" Manhattan 
    , row "Euklid" Euclid
    , row "Wulf" Wulf
      ]
 where
  row name metric' =
    Tuple (H.a [ E.onClick (E.input_ (Use metric')) ] [ H.text name ]) (metric==metric')

type Entry = { player :: Player, points :: Number }

entriesForStandings :: Metric -> Array Team -> Array Entry
entriesForStandings metric standings =
  sortBy
    (compare `on` _.points)
    (map (\p -> { player: p, points: ratePlayer metric standings p }) allPlayers)

pointsTable :: forall p. Array Entry -> H.HTML p (Input Unit)
pointsTable entries =
  H.table
    [P.class_ (H.className "table")]
    [H.thead_ [pointsHeader], H.tbody_ (zipWith pointsRow (range 1 (length entries)) entries)]
 where
  pointsHeader = H.tr_ [H.th_ [H.text "#"], H.th_ [H.text "Tipper"], H.th_ [H.text "Punkte"]]
  pointsRow i entry =
    H.tr_
      [ H.td_ [H.text (show i)]
      , H.td_ [H.a [P.href (reverseRoute (TipsRoute entry.player))] [H.text (show entry.player)]]
      , H.td_ [H.text (showNumber entry.points 1)] ]

tipTable :: forall p i. Metric -> Array Team -> Array Team -> H.HTML p i
tipTable metric tip standings =
  H.table
    [P.class_ (H.className "table")]
    [H.thead_ [tipHeader], H.tbody_ (zipWith tipRow (range 1 (length tip)) tip)]
 where
  tipHeader = H.tr_ [H.th_ [H.text "#"], H.th_ [H.text "Verein"], H.th_ [H.text "Abstand"]]
  tipRow i team =
    let dist = case fromNumber (rateTip Manhattan standings team i) of
                    Just i -> i
        p = rateTip metric standings team i
        t = trend standings team i
    in
    H.tr
      [rowColor dist t]
      [ H.td_ [H.text (show i)]
      , H.td_ [H.text (pretty team)]
      , H.td_ [H.text (showNumber p 1)] ]

rowColor :: forall i. Int -> Trend -> H.Prop i
rowColor dist trend =
  P.classes [H.className (trendClass trend), H.className (distClass dist)]
 where
  trendClass Correct = "correct"
  trendClass Worse   = "worse"
  trendClass Better  = "better"
  distClass i = "dist-" ++ show i


renderCurrentTable :: forall p i. Array Team -> H.HTML p i
renderCurrentTable standings =
  H.div [P.class_ (H.className "current-table")]
        [ H.div [P.class_ (H.className "current-table-row")] (take 9 icons)
        , H.div [P.class_ (H.className "current-table-row")] (drop 9 icons)
        , H.div [P.class_ (H.className "clear")] [] ]
 where
  icons = map icon standings
  icon team =
    H.div [P.class_ (H.className "team")]
          [H.img [P.src ("images/" ++ show team ++ ".svg"), P.class_ (H.className "icon")]]


showNumber :: Number -> Int -> String
showNumber p d = show (roundTo p d)
 
roundTo :: Number -> Int -> Number
roundTo x d = round (x * m) / m
 where
  m = pow 10.0 (toNumber d)
