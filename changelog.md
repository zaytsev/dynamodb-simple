# 0.6.0.0

- add dDecodeEither method to DynamoEncodable for better error reporting
- removed hack for faulty AWSpager form 1.4.5 amazonka-dynamodb

# 0.5.0.0

- Added UUID DynamoEncodable instance

# 0.4.0.1

- Fixed default signatures to compile with GHC 8.2

# 0.4.0.0

- Slightly changed TH API to allow table prefixing
- Better consistency settings detection for queryOverIndex

# 0.3.0.0

- API changes regarding position of `Proxy`
- Added index->table conversion functions
- Added conduits for left/inner join
- Added queryOverIndex
- Simplification of exposed function signatures

# 0.2.0.0

- Changed API to always include a `Proxy`
- Added proxy generation (`tTable`, `iTableIndex`)
- Added polymorphic lenses for fields starting with underscore
- Changed generated column names from `colColumn` to `column'`
- Overriden buggy amazonka paging
