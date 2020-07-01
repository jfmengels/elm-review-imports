module NoInconsistentAliases.Visitor exposing (rule)

import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node(..))
import List.Nonempty as Nonempty exposing (Nonempty)
import NoInconsistentAliases.BadAlias as BadAlias exposing (BadAlias)
import NoInconsistentAliases.Config exposing (Config)
import NoInconsistentAliases.Context as Context
import NoInconsistentAliases.MissingAlias as MissingAlias exposing (MissingAlias)
import NoInconsistentAliases.ModuleUse as ModuleUse exposing (ModuleUse)
import NoInconsistentAliases.Visitor.Options as Options exposing (Options)
import Review.Fix as Fix exposing (Fix)
import Review.Rule as Rule exposing (Error, Rule)
import Set
import Vendor.NameVisitor as NameVisitor


rule : Config -> Rule
rule config =
    let
        options : Options
        options =
            Options.fromConfig config
    in
    Rule.newModuleRuleSchema "NoInconsistentAliases" Context.initial
        |> Rule.withImportVisitor (importVisitor options)
        |> NameVisitor.withNameVisitor moduleCallVisitor
        |> Rule.withFinalModuleEvaluation finalEvaluation
        |> Rule.fromModuleRuleSchema


importVisitor : Options -> Node Import -> Context.Module -> ( List (Error {}), Context.Module )
importVisitor options (Node _ { moduleName, moduleAlias }) context =
    ( []
    , context
        |> rememberModuleAlias moduleName moduleAlias
        |> rememberBadAlias options moduleName moduleAlias
    )


rememberModuleAlias : Node ModuleName -> Maybe (Node ModuleName) -> Context.Module -> Context.Module
rememberModuleAlias moduleName maybeModuleAlias context =
    let
        moduleAlias =
            maybeModuleAlias |> Maybe.withDefault moduleName |> Node.map formatModuleName
    in
    context |> Context.addModuleAlias (Node.value moduleName) (Node.value moduleAlias)


rememberBadAlias : Options -> Node ModuleName -> Maybe (Node ModuleName) -> Context.Module -> Context.Module
rememberBadAlias { lookupAliases, canMissAliases } (Node moduleNameRange moduleName) maybeModuleAlias context =
    case ( lookupAliases moduleName, maybeModuleAlias ) of
        ( Just expectedAliases, Just (Node moduleAliasRange moduleAlias) ) ->
            let
                badAlias =
                    BadAlias.new
                        { name = moduleAlias |> formatModuleName
                        , moduleName = moduleName
                        , expectedNames = expectedAliases
                        , range = moduleAliasRange
                        }
            in
            context |> Context.addBadAlias badAlias

        ( Just expectedAliases, Nothing ) ->
            if canMissAliases then
                context

            else
                let
                    missingAlias =
                        MissingAlias.new moduleName expectedAliases moduleNameRange
                in
                context |> Context.addMissingAlias missingAlias

        ( Nothing, _ ) ->
            context


moduleCallVisitor : Node ( ModuleName, String ) -> Context.Module -> ( List (Error {}), Context.Module )
moduleCallVisitor node context =
    case Node.value node of
        ( moduleName, function ) ->
            ( [], Context.addModuleCall moduleName function (Node.range node) context )


finalEvaluation : Context.Module -> List (Error {})
finalEvaluation context =
    let
        lookupModuleNames =
            Context.lookupModuleNames context
    in
    Context.foldBadAliases (foldBadAliasError lookupModuleNames) [] context
        ++ Context.foldMissingAliases (foldMissingAliasError lookupModuleNames) [] context


foldBadAliasError : ModuleNameLookup -> BadAlias -> List (Error {}) -> List (Error {})
foldBadAliasError lookupModuleNames badAlias errors =
    let
        moduleName =
            badAlias |> BadAlias.mapModuleName identity

        badRange =
            BadAlias.range badAlias

        badAliasName =
            badAlias |> BadAlias.mapName identity

        expectedAliases =
            badAlias |> BadAlias.mapExpectedNames identity

        aliasClashes =
            detectCollisions (lookupModuleNames badAliasName) moduleName

        availableAliases =
            findAvailableAliases lookupModuleNames moduleName expectedAliases
    in
    case availableAliases of
        expectedAlias :: _ ->
            if badAliasName == expectedAlias then
                errors

            else
                case aliasClashes of
                    [] ->
                        let
                            fixes =
                                Fix.replaceRangeBy badRange expectedAlias
                                    :: BadAlias.mapUses (fixModuleUse expectedAlias) badAlias
                        in
                        Rule.errorWithFix (incorrectAliasError expectedAlias badAlias) badRange fixes
                            :: errors

                    _ :: _ ->
                        Rule.error (incorrectAliasError expectedAlias badAlias) badRange
                            :: errors

        [] ->
            let
                expectedAlias =
                    Nonempty.last expectedAliases
            in
            Rule.error (collisionAliasError expectedAlias badAlias) badRange
                :: errors


foldMissingAliasError : ModuleNameLookup -> MissingAlias -> List (Error {}) -> List (Error {})
foldMissingAliasError lookupModuleNames missingAlias errors =
    if MissingAlias.hasUses missingAlias then
        let
            expectedAliases =
                missingAlias |> MissingAlias.mapExpectedNames identity

            moduleName =
                missingAlias |> MissingAlias.mapModuleName identity

            badRange =
                MissingAlias.range missingAlias

            availableAliases =
                findAvailableAliases lookupModuleNames moduleName expectedAliases
        in
        case availableAliases of
            expectedAlias :: _ ->
                let
                    fixes =
                        Fix.insertAt badRange.end (" as " ++ expectedAlias)
                            :: MissingAlias.mapUses (fixModuleUse expectedAlias) missingAlias
                in
                Rule.errorWithFix (missingAliasError expectedAlias missingAlias) badRange fixes
                    :: errors

            _ ->
                Rule.error (missingAliasCollisionError (Nonempty.head expectedAliases) missingAlias) badRange
                    :: errors

    else
        errors


findAvailableAliases : ModuleNameLookup -> ModuleName -> Nonempty String -> List String
findAvailableAliases lookupModuleNames moduleName expectedAliases =
    let
        moduleClashes =
            Nonempty.foldl
                (\aliasName set ->
                    case detectCollisions (lookupModuleNames aliasName) moduleName of
                        [] ->
                            set

                        _ ->
                            Set.insert aliasName set
                )
                Set.empty
                expectedAliases
    in
    expectedAliases
        |> Nonempty.toList
        |> List.filter (\aliasName -> not (Set.member aliasName moduleClashes))


detectCollisions : List ModuleName -> ModuleName -> List ModuleName
detectCollisions collisionNames moduleName =
    List.filter ((/=) moduleName) collisionNames


incorrectAliasError : String -> BadAlias -> { message : String, details : List String }
incorrectAliasError expectedAlias badAlias =
    let
        badAliasName =
            BadAlias.mapName identity badAlias

        moduleName =
            BadAlias.mapModuleName formatModuleName badAlias
    in
    { message = incorrectAliasMessage badAliasName moduleName
    , details = incorrectAliasDetails expectedAlias moduleName
    }


collisionAliasError : String -> BadAlias -> { message : String, details : List String }
collisionAliasError expectedAlias badAlias =
    let
        badAliasName =
            BadAlias.mapName identity badAlias

        moduleName =
            BadAlias.mapModuleName formatModuleName badAlias
    in
    { message = incorrectAliasMessage badAliasName moduleName
    , details = collisionAliasDetails expectedAlias moduleName
    }


missingAliasError : String -> MissingAlias -> { message : String, details : List String }
missingAliasError expectedAlias missingAlias =
    let
        moduleName =
            MissingAlias.mapModuleName formatModuleName missingAlias
    in
    { message = expectedAliasMessage expectedAlias moduleName
    , details = incorrectAliasDetails expectedAlias moduleName
    }


missingAliasCollisionError : String -> MissingAlias -> { message : String, details : List String }
missingAliasCollisionError expectedAlias missingAlias =
    let
        moduleName =
            MissingAlias.mapModuleName formatModuleName missingAlias
    in
    { message = expectedAliasMessage expectedAlias moduleName
    , details = collisionAliasDetails expectedAlias moduleName
    }


incorrectAliasMessage : String -> String -> String
incorrectAliasMessage badAliasName moduleName =
    "Incorrect alias `" ++ badAliasName ++ "` for module `" ++ moduleName ++ "`."


expectedAliasMessage : String -> String -> String
expectedAliasMessage expectedAlias moduleName =
    "Expected alias `" ++ expectedAlias ++ "` missing for module `" ++ moduleName ++ "`."


incorrectAliasDetails : String -> String -> List String
incorrectAliasDetails expectedAlias moduleName =
    [ "This import does not use your preferred alias `" ++ expectedAlias ++ "` for `" ++ moduleName ++ "`."
    , "You should update the alias to be consistent with the rest of the project. Remember to change all references to the alias in this module too."
    ]


collisionAliasDetails : String -> String -> List String
collisionAliasDetails expectedAlias moduleName =
    [ "This import does not use your preferred alias `" ++ expectedAlias ++ "` for `" ++ moduleName ++ "`."
    , "Your preferred alias has already been used by another module so you should review carefully whether to overload this alias or configure another."
    , "If you change this alias remember to change all references to the alias in this module too."
    ]


fixModuleUse : String -> ModuleUse -> Fix
fixModuleUse expectedAlias use =
    Fix.replaceRangeBy (ModuleUse.range use) (ModuleUse.mapFunction (\name -> expectedAlias ++ "." ++ name) use)


formatModuleName : ModuleName -> String
formatModuleName moduleName =
    String.join "." moduleName


type alias ModuleNameLookup =
    String -> List ModuleName
