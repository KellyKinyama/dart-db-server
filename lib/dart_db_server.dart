/// Public API of the dart-db-server library.
library;

export 'server/client.dart';
export 'server/concurrency.dart';
export 'server/database.dart';
export 'server/blob.dart';
export 'server/session.dart';
export 'server/expression.dart' show Expr;
export 'server/mysql_wire.dart' show MySqlServer;
export 'server/fts5.dart'
    show
        tokenizeFts,
        fts5Match,
        parseFts5Query,
        Fts5Node,
        fts5Bm25,
        fts5TermFrequency,
        Fts5Index;
export 'server/prepared.dart';
export 'server/result.dart';
export 'server/rtree.dart' show BBox, RTreeIndex;
export 'server/vector.dart'
    show
        Vector,
        VectorMetric,
        VectorIndexKind,
        VectorIndexSpec,
        VectorSearchHit,
        FlatIndex,
        HnswIndex,
        IvfFlatIndex,
        LshIndex,
        PqIndex,
        IvfPqIndex,
        vectorIndexBuiltStateToJson,
        vectorIndexBuiltStateFromJson,
        encodeVectorBlob,
        decodeVectorBlob,
        parseVectorText,
        parseVectorBatchText,
        coerceVector,
        vecL2,
        vecL2Sq,
        vecInnerProduct,
        vecCosineDistance,
        vecCosineSimilarity,
        vecNorm,
        vecNormalize,
        vecAdd,
        vecSub;
export 'server/schema.dart';
export 'server/server.dart';
export 'server/sqlite_format.dart';
export 'server/statement.dart';
export 'server/table_backend.dart' show TableBackend, TableBackendKind;
export 'server/table.dart' show Table, IndexDef;
