{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Data.OpenApi.Schema.Generator where

import           Prelude                                 ()
import           Prelude.Compat

import           Control.Lens.Operators
import           Data.Aeson
import           Data.Aeson.Types
import qualified Data.HashMap.Strict.InsOrd              as M
import           Data.Maybe
import           Data.Proxy
import           Data.Scientific
import qualified Data.Set                                as S
import           Data.OpenApi
import           Data.OpenApi.Declare
import           Data.OpenApi.Internal.Schema.Validation (inferSchemaTypes)
import           Data.Text                               (Text)
import qualified Data.Text                               as T
import qualified Data.Vector                             as V
import           GHC.Stack                               (HasCallStack)
import           Test.QuickCheck                         (arbitrary)
import           Test.QuickCheck.Gen
import           Test.QuickCheck.Property

import Data.OpenApi.Aeson.Compat (fromInsOrdHashMap)

-- | Note: 'schemaGen' may 'error', if schema type is not specified,
-- and cannot be inferred.
schemaGen :: HasCallStack => Definitions Schema -> Schema -> Gen Value
schemaGen = schemaGenWithFormats (const Nothing)

schemaGenWithFormats :: HasCallStack => (Format -> Maybe (Gen Text)) -> Definitions Schema -> Schema -> Gen Value
schemaGenWithFormats _ _ schema
    | Just cases <- schema  ^. enum_  = elements cases
schemaGenWithFormats _ defns schema
    | Just variants <- schema ^. oneOf = schemaGen defns =<< elements (dereference defns <$> variants)
schemaGenWithFormats formatGen defns schema =
    case schema ^. type_ of
      Nothing ->
        case inferSchemaTypes schema of
          [ inferredType ] -> schemaGenWithFormats formatGen defns (schema & type_ ?~ inferredType)
          -- Gen is not MonadFail
          _ -> error "unable to infer schema type"
      Just OpenApiBoolean -> Bool <$> elements [True, False]
      Just OpenApiNull    -> pure Null
      Just OpenApiNumber
        | Just min <- schema ^. minimum_
        , Just max <- schema ^. maximum_ ->
            Number . fromFloatDigits <$>
                   choose (toRealFloat min, toRealFloat max :: Double)
        | otherwise -> Number .fromFloatDigits <$> (arbitrary :: Gen Double)
      Just OpenApiInteger
        | Just min <- schema ^. minimum_
        , Just max <- schema ^. maximum_ ->
            Number . fromInteger <$>
                   choose (truncate min, truncate max)
        | otherwise -> Number . fromInteger <$> arbitrary
      Just OpenApiArray
        | Just 0 <- schema ^. maxLength -> pure $ Array V.empty
        | Just items <- schema ^. items ->
            case items of
              OpenApiItemsObject ref -> do
                  size <- getSize
                  let itemSchema = dereference defns ref
                      minLength' = fromMaybe 0 $ fromInteger <$> schema ^. minItems
                      maxLength' = fromMaybe size $ fromInteger <$> schema ^. maxItems
                  arrayLength <- choose (minLength', max minLength' maxLength')
                  generatedArray <- vectorOf arrayLength $ schemaGenWithFormats formatGen defns itemSchema
                  return . Array $ V.fromList generatedArray
              OpenApiItemsArray refs ->
                  let itemGens = schemaGenWithFormats formatGen defns . dereference defns <$> refs
                  in fmap (Array . V.fromList) $ sequence itemGens
        | otherwise -> error "invalid array"
      Just OpenApiString
        | Just gen <- formatGen =<< schema ^. format ->
            String <$> gen
        | otherwise -> do
        size <- getSize
        let minLength' = fromMaybe 0 $ fromInteger <$> schema ^. minLength
        let maxLength' = fromMaybe size $ fromInteger <$> schema ^. maxLength
        length <- choose (minLength', max minLength' maxLength')
        str <- vectorOf length arbitrary
        return . String $ T.pack str
      Just OpenApiObject -> do
          size <- getSize
          let props = dereference defns <$> schema ^. properties
              reqKeys = S.fromList $ schema ^. required
              allKeys = S.fromList . M.keys $ schema ^. properties
              optionalKeys = allKeys S.\\ reqKeys
              minProps' = fromMaybe (length reqKeys) $
                            fromInteger <$> schema ^. minProperties
              maxProps' = fromMaybe size $ fromInteger <$> schema ^. maxProperties
          shuffledOptional <- shuffle $ S.toList optionalKeys
          numProps <- choose (minProps', max minProps' maxProps')
          let presentKeys = take numProps $ S.toList reqKeys ++ shuffledOptional
          let presentProps = M.filterWithKey (\k _ -> k `elem` presentKeys) props
          let gens = schemaGenWithFormats formatGen defns <$> presentProps
          additionalGens <- case schema ^. additionalProperties of
            Just (AdditionalPropertiesSchema addlSchema) -> do
              additionalKeys <- sequence . take (numProps - length presentProps) . repeat $ T.pack <$> arbitrary
              return . M.fromList $ zip additionalKeys (repeat . schemaGenWithFormats formatGen defns $ dereference defns addlSchema)
            _                                      -> return []
          x <- sequence $ gens <> additionalGens
          return . Object $ fromInsOrdHashMap x

dereference :: Definitions a -> Referenced a -> a
dereference _ (Inline a)               = a
dereference defs (Ref (Reference ref)) = fromJust $ M.lookup ref defs

genValue :: (ToSchema a) => Proxy a -> Gen Value
genValue p =
 let (defs, NamedSchema _ schema) = runDeclare (declareNamedSchema p) M.empty
 in schemaGen defs schema

validateFromJSON :: forall a . (ToSchema a, FromJSON a) => Proxy a -> Property
validateFromJSON p = forAll (genValue p) $
                       \val -> case parseEither parseJSON val of
                                 Right (_ :: a) -> succeeded
                                 Left err -> failed
                                               { reason = err
                                               }
