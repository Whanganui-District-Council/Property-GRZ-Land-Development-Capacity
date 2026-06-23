-- FUNCTION: property.property_buildings_ranking(integer, integer)

-- DROP FUNCTION IF EXISTS property.property_buildings_ranking(integer, integer);

CREATE OR REPLACE FUNCTION property.property_buildings_ranking(
	p_prop_no integer,
	p_limit integer DEFAULT 3)
    RETURNS TABLE(rank bigint, area double precision, dist_to_frontage double precision, alignment_score double precision, back_penalty double precision, score double precision, is_likely_dwelling boolean, frontage_distance_geom geometry, building_position geometry, building_geom geometry) 
    LANGUAGE 'plpgsql'
    COST 100
    STABLE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
BEGIN
    RETURN QUERY

    WITH prop AS (
        SELECT p.geom
        FROM property.property_eplan_zones p
        WHERE p.prop_no = p_prop_no
    ),

    frontage AS (
        SELECT ST_Union(f.geom) AS geom
        FROM property.property_road_frontage f
        WHERE f.prop_no = p_prop_no
    ),

    -- ✅ all frontage segments
    frontage_segments AS (
        SELECT (ST_Dump(ST_CollectionExtract(fr.geom, 2))).geom AS seg
        FROM frontage fr
        WHERE fr.geom IS NOT NULL
    ),

    -- ✅ fallback midpoint (longest segment)
    frontage_midpoint AS (
        SELECT
            (
                SELECT ST_LineInterpolatePoint(fs.seg, 0.5)
                FROM frontage_segments fs
                ORDER BY ST_Length(fs.seg) DESC
                LIMIT 1
            ) AS geom
    ),

    -- ✅ buildings clipped to parcel + perpendicular frontage distance
    buildings AS (
        SELECT 
            g.geom,
            ST_Area(g.geom) AS area,

            -- ✅ perpendicular distance geometry
            (
                SELECT ST_ShortestLine(
                    ST_Centroid(g.geom),
                    fs.seg
                )
                FROM frontage_segments fs
                ORDER BY ST_Distance(ST_Centroid(g.geom), fs.seg)
                LIMIT 1
            ) AS frontage_distance_geom,

            -- ✅ distance from that geometry
            ST_Length(
                (
                    SELECT ST_ShortestLine(
                        ST_Centroid(g.geom),
                        fs.seg
                    )
                    FROM frontage_segments fs
                    ORDER BY ST_Distance(ST_Centroid(g.geom), fs.seg)
                    LIMIT 1
                )
            ) AS dist_to_frontage

        FROM (
            SELECT ST_Intersection(b.geom, p.geom) AS geom
            FROM property.building_footprints_2025 b
            JOIN prop p ON ST_Intersects(b.geom, p.geom)
            WHERE COALESCE(b.status, '') <> 'Deleted'
        ) g
        WHERE 
            g.geom IS NOT NULL
            AND NOT ST_IsEmpty(g.geom)
            AND ST_Area(g.geom) >= 60
    ),

    building_orientation AS (
        SELECT 
            b.geom,
            b.area,
            b.dist_to_frontage,
            b.frontage_distance_geom,
            ST_Azimuth(
                ST_PointN(box, 1),
                ST_PointN(box, 2)
            ) AS b_azimuth
        FROM (
            SELECT 
                b.geom,
                b.area,
                b.dist_to_frontage,
                b.frontage_distance_geom,
                ST_ExteriorRing(ST_OrientedEnvelope(b.geom)) AS box
            FROM buildings b
        ) b
    ),

    classified AS (
        SELECT 
            bo.*,
            CASE 
                WHEN bo.area > 120 AND bo.dist_to_frontage < 50 THEN TRUE
                ELSE FALSE
            END AS is_likely_dwelling
        FROM building_orientation bo
    ),

    -- ✅ best alignment across all frontage segments
    aligned AS (
        SELECT 
            c.*,
            (
                SELECT MAX(
                    ABS(
                        COS(
                            c.b_azimuth -
                            ST_Azimuth(
                                ST_StartPoint(fs.seg),
                                ST_EndPoint(fs.seg)
                            )
                        )
                    )
                )
                FROM frontage_segments fs
            ) AS alignment_score
        FROM classified c
    ),

    -- ✅ back-of-property penalty
    with_back_distance AS (
        SELECT 
            a.*,
            ST_Distance(
                ST_Centroid(a.geom),
                ST_Boundary(p.geom)
            ) AS dist_to_boundary
        FROM aligned a
        JOIN prop p ON TRUE
    ),

    penalised AS (
        SELECT 
            w.*,
            (w.dist_to_boundary / NULLIF(MAX(w.dist_to_boundary) OVER (), 0)) AS back_penalty
        FROM with_back_distance w
    ),

    ranked AS (
        SELECT 
            p.*,
            (
                (p.area / NULLIF(MAX(p.area) OVER (), 0)) * 0.45
                +
                ((1 - (p.dist_to_frontage / NULLIF(MAX(p.dist_to_frontage) OVER (), 0))) * 0.25)
                +
                (COALESCE(p.alignment_score, 0) * 0.15)
                +
                (CASE WHEN p.is_likely_dwelling THEN 0.10 ELSE 0 END)
                -
                (p.back_penalty * 0.15)
            ) AS score
        FROM penalised p
    ),

    ordered AS (
        SELECT 
            r.*,
            ROW_NUMBER() OVER (ORDER BY r.score DESC) AS rank
        FROM ranked r
    ),

    final_ranked AS (
        SELECT
            o.rank,
            o.area,
            o.dist_to_frontage,
            o.alignment_score,
            o.back_penalty,
            o.score,
            o.is_likely_dwelling,
            o.frontage_distance_geom,

            -- ✅ snap to nearest frontage segment
            (
                SELECT ST_ClosestPoint(o.geom, fs.seg)
                FROM frontage_segments fs
                ORDER BY ST_Distance(o.geom, fs.seg)
                LIMIT 1
            ) AS building_position,

            o.geom AS building_geom

        FROM ordered o
        WHERE o.rank <= p_limit
    )

    -- ✅ main results
    SELECT * FROM final_ranked

    UNION ALL

    -- ✅ fallback
    SELECT
        1 AS rank,
        NULL::double precision,
        NULL::double precision,
        NULL::double precision,
        NULL::double precision,
        NULL::double precision,
        NULL::boolean,
        NULL::geometry,
        COALESCE(fm.geom, ST_PointOnSurface(p.geom)),
        NULL::geometry
    FROM prop p
    LEFT JOIN frontage_midpoint fm ON TRUE
    WHERE NOT EXISTS (SELECT 1 FROM final_ranked);

END;
$BODY$;

ALTER FUNCTION property.property_buildings_ranking(integer, integer)
    OWNER TO postgres;

GRANT EXECUTE ON FUNCTION property.property_buildings_ranking(integer, integer) TO PUBLIC;

GRANT EXECUTE ON FUNCTION property.property_buildings_ranking(integer, integer) TO postgres;

GRANT EXECUTE ON FUNCTION property.property_buildings_ranking(integer, integer) TO wdc;

GRANT EXECUTE ON FUNCTION property.property_buildings_ranking(integer, integer) TO wdc_gisprod;

