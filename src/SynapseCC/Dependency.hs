{-# LANGUAGE OverloadedStrings #-}

-- | Dependency graph resolution for cache invalidation
module SynapseCC.Dependency
  ( -- * Dependency graph operations
    buildDependencyGraph
  , findInvalidPlugins
  , topologicalSort
  , DependencyGraph
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)

-- ============================================================================
-- Types
-- ============================================================================

-- | Dependency graph: plugin name -> list of dependencies
type DependencyGraph = Map Text [Text]

-- ============================================================================
-- Graph Construction
-- ============================================================================

-- | Build dependency graph from IR plugin cache
-- Maps each plugin to its list of dependencies
buildDependencyGraph :: Map Text [Text] -> DependencyGraph
buildDependencyGraph pluginDeps = pluginDeps

-- ============================================================================
-- Invalidation Resolution
-- ============================================================================

-- | Find all plugins that need regeneration due to dependencies
-- Takes a set of initially invalid plugins and a dependency graph,
-- returns all plugins that are transitively invalid.
--
-- Example:
--   If 'arbor' is invalid and 'cone' depends on 'arbor',
--   then both 'arbor' and 'cone' are invalid.
findInvalidPlugins
  :: Set Text          -- ^ Initially invalid plugins
  -> DependencyGraph   -- ^ Dependency map (plugin -> its dependencies)
  -> Set Text          -- ^ All invalid plugins (with transitive deps)
findInvalidPlugins initialInvalid depGraph =
  let -- Find reverse dependencies: which plugins depend on each plugin
      reverseDeps = buildReverseDependencyMap depGraph

      -- Recursively find all dependents
      allInvalid = fixpoint (expandInvalid reverseDeps) initialInvalid
  in allInvalid

-- | Build reverse dependency map: for each plugin, which other plugins depend on it
buildReverseDependencyMap :: DependencyGraph -> Map Text (Set Text)
buildReverseDependencyMap depGraph =
  Map.foldrWithKey addReverseDeps Map.empty depGraph
  where
    addReverseDeps :: Text -> [Text] -> Map Text (Set Text) -> Map Text (Set Text)
    addReverseDeps plugin deps acc =
      foldr (\dep m -> Map.insertWith Set.union dep (Set.singleton plugin) m) acc deps

-- | Expand the set of invalid plugins by one step (add direct dependents)
expandInvalid :: Map Text (Set Text) -> Set Text -> Set Text
expandInvalid reverseDeps invalid =
  let -- Find all plugins that directly depend on any invalid plugin
      newInvalid = Set.foldr
        (\invalidPlugin acc ->
          case Map.lookup invalidPlugin reverseDeps of
            Nothing -> acc  -- No dependents
            Just dependents -> Set.union acc dependents
        )
        Set.empty
        invalid
  in Set.union invalid newInvalid

-- | Apply a function repeatedly until the result stops changing (fixed point)
fixpoint :: Eq a => (a -> a) -> a -> a
fixpoint f x =
  let x' = f x
  in if x' == x then x else fixpoint f x'

-- ============================================================================
-- Topological Sort
-- ============================================================================

-- | Topological sort for regeneration order
-- Returns plugins in dependency order (dependencies before dependents)
-- If there are cycles, returns an arbitrary but valid partial order
topologicalSort :: DependencyGraph -> [Text]
topologicalSort depGraph =
  let allPlugins = Set.union
        (Map.keysSet depGraph)
        (Set.unions $ map Set.fromList $ Map.elems depGraph)
      sorted = topSort depGraph allPlugins []
  in sorted

-- | Kahn's algorithm for topological sorting
topSort :: DependencyGraph -> Set Text -> [Text] -> [Text]
topSort depGraph remaining acc
  | Set.null remaining = reverse acc
  | otherwise =
      -- Find nodes with no dependencies (or all dependencies already processed)
      let nodesWithNoDeps = Set.filter (hasNoDependencies depGraph (Set.fromList acc)) remaining
      in if Set.null nodesWithNoDeps
           then
             -- Cycle detected or no more nodes without deps
             -- Just take remaining nodes in arbitrary order
             reverse acc ++ Set.toList remaining
           else
             -- Process one node with no dependencies
             let node = Set.findMin nodesWithNoDeps
                 remaining' = Set.delete node remaining
             in topSort depGraph remaining' (node : acc)

-- | Check if a plugin has no unprocessed dependencies
hasNoDependencies :: DependencyGraph -> Set Text -> Text -> Bool
hasNoDependencies depGraph processed plugin =
  case Map.lookup plugin depGraph of
    Nothing -> True  -- No dependencies
    Just deps -> all (`Set.member` processed) deps
