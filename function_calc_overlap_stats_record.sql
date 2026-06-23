DROP FUNCTION IF EXISTS general.calc_overlap_stats_record(geometry, text, text, text, text);

CREATE OR REPLACE FUNCTION general.calc_overlap_stats_record(
    geom_a geometry,
    schema_name text,
    table_name text,
    where_clause text DEFAULT NULL,
    geom_b_column text DEFAULT 'geom',
    OUT overlap_geom geometry,
    OUT overlap_area double precision,
    OUT overlap_pct double precision
)
RETURNS record
LANGUAGE plpgsql
AS $BODY$
DECLARE
    sql text;
    geom_a_area double precision;
BEGIN
    -- Clean and normalize input geometry
    geom_a := ST_SetSRID(ST_MakeValid(geom_a), ST_SRID(geom_a));
    geom_a_area := ST_Area(geom_a);

    -- Early exit if zero area
    IF geom_a_area = 0 THEN
        overlap_geom := ST_SetSRID('MULTIPOLYGON EMPTY'::geometry, ST_SRID(geom_a));
        overlap_area := 0;
        overlap_pct  := 0;
        RETURN;
    END IF;

    -- Dynamic SQL: intersect per feature, then dissolve into one geometry
    sql := format(
        $f$
        WITH intersections AS (
            SELECT
                ST_Intersection(
                    $1,
                    ST_SetSRID(ST_MakeValid(%I), ST_SRID($1))
                ) AS geom
            FROM %I.%I
            WHERE %I && $1
              AND ST_Intersects($1, %I)
              %s
        ),
        cleaned AS (
            SELECT geom
            FROM intersections
            WHERE NOT ST_IsEmpty(geom)
        )
        SELECT
            COALESCE(
                ST_UnaryUnion(ST_Collect(geom)),
                ST_SetSRID('GEOMETRYCOLLECTION EMPTY'::geometry, ST_SRID($1))
            )
        FROM cleaned
        $f$,
        geom_b_column,
        schema_name,
        table_name,
        geom_b_column,
        geom_b_column,
        CASE 
            WHEN where_clause IS NOT NULL THEN 'AND (' || where_clause || ')'
            ELSE ''
        END
    );

    -- Execute query
    EXECUTE sql INTO overlap_geom USING geom_a;

    -- Final cleanup: validity, SRID, enforce multipolygon
    overlap_geom := ST_Multi(
        ST_SetSRID(
            ST_MakeValid(
                COALESCE(
                    overlap_geom,
                    'GEOMETRYCOLLECTION EMPTY'::geometry
                )
            ),
            ST_SRID(geom_a)
        )
    );

    -- Calculate area and percentage
    overlap_area := ST_Area(overlap_geom);
    overlap_pct  := (overlap_area / geom_a_area) * 100;

    RETURN;
END;
$BODY$;

-- Ownership
ALTER FUNCTION general.calc_overlap_stats_record(geometry, text, text, text, text)
    OWNER TO postgres;

-- Permissions
GRANT EXECUTE ON FUNCTION general.calc_overlap_stats_record(geometry, text, text, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION general.calc_overlap_stats_record(geometry, text, text, text, text) TO postgres;
GRANT EXECUTE ON FUNCTION general.calc_overlap_stats_record(geometry, text, text, text, text) TO wdc;
GRANT EXECUTE ON FUNCTION general.calc_overlap_stats_record(geometry, text, text, text, text) TO wdc_gisprod;