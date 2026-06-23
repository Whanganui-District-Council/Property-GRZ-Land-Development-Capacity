-- PROCEDURE: property.create_mv_property_grz_ldcap_building_quadrant_stats()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap_building_quadrant_stats();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_stats(
	)
LANGUAGE 'sql'
AS $BODY$
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_building_quadrant_stats;

CREATE MATERIALIZED VIEW property.property_grz_ldcap_building_quadrant_stats AS
WITH prop AS (
    SELECT prop_no, geom, layer
    FROM property.property_eplan_zones
    WHERE layer = ANY (
        ARRAY[
            'grz_general_residential_zone'
        ]
    )
),

split_base AS (
    SELECT
        prop_no,
        geom,
        layer,
        ST_Centroid(geom) AS center,
        ST_Envelope(geom) AS bbox,
        ST_SRID(geom) AS srid
    FROM prop
),

split_axes AS (
    SELECT
        prop_no,
        ST_MakeLine(
            ST_SetSRID(ST_MakePoint(ST_X(center), ST_YMin(bbox)), srid),
            ST_SetSRID(ST_MakePoint(ST_X(center), ST_YMax(bbox)), srid)
        ) AS vline,
        ST_MakeLine(
            ST_SetSRID(ST_MakePoint(ST_XMin(bbox), ST_Y(center)), srid),
            ST_SetSRID(ST_MakePoint(ST_XMax(bbox), ST_Y(center)), srid)
        ) AS hline
    FROM split_base
),

split_parts AS (
    SELECT
        p.prop_no,
        p.layer,
        (ST_Dump(
            ST_Split(
                ST_Split(p.geom, sa.vline),
                sa.hline
            )
        )).geom AS geom,
        sb.center
    FROM prop p
    JOIN split_axes sa USING (prop_no)
    JOIN split_base sb USING (prop_no)
),

quadrant_parts AS (
    SELECT
        sp.prop_no,
        sp.layer,
        sp.geom AS quadrant_geom,

        CASE
            WHEN ST_X(ST_Centroid(sp.geom)) >= ST_X(sp.center)
             AND ST_Y(ST_Centroid(sp.geom)) >= ST_Y(sp.center) THEN 1
            WHEN ST_X(ST_Centroid(sp.geom)) < ST_X(sp.center)
             AND ST_Y(ST_Centroid(sp.geom)) >= ST_Y(sp.center) THEN 2
            WHEN ST_X(ST_Centroid(sp.geom)) >= ST_X(sp.center)
             AND ST_Y(ST_Centroid(sp.geom)) < ST_Y(sp.center) THEN 3
            ELSE 4
        END AS quadrant_id,

        CASE
            WHEN ST_X(ST_Centroid(sp.geom)) >= ST_X(sp.center)
             AND ST_Y(ST_Centroid(sp.geom)) >= ST_Y(sp.center) THEN 'NE'
            WHEN ST_X(ST_Centroid(sp.geom)) < ST_X(sp.center)
             AND ST_Y(ST_Centroid(sp.geom)) >= ST_Y(sp.center) THEN 'NW'
            WHEN ST_X(ST_Centroid(sp.geom)) >= ST_X(sp.center)
             AND ST_Y(ST_Centroid(sp.geom)) < ST_Y(sp.center) THEN 'SE'
            ELSE 'SW'
        END AS quadrant,

        COALESCE((
            SELECT SUM(
                ST_Length(ST_Intersection(ST_Boundary(sp.geom), rf.geom))
            )
            FROM property.property_road_frontage rf
            WHERE rf.prop_no = sp.prop_no
              AND ST_Touches(sp.geom, rf.geom)
        ), 0) AS frontage_length

    FROM split_parts sp
),

frontage_rank AS (
    SELECT *,
        (frontage_length > 0 AND
         frontage_length = MAX(frontage_length) OVER (PARTITION BY prop_no)
        ) AS quadrant_is_front_facing
    FROM quadrant_parts
),

building_clip AS (
    SELECT
        p.prop_no,
        p.layer,
        b.ctid AS building_id,
        ST_Intersection(b.geom, p.geom) AS geom
    FROM property.building_footprints_2025 b
    JOIN prop p ON ST_Intersects(b.geom, p.geom)
    WHERE b.status <> 'Deleted'
      AND ST_Area(b.geom) >= 60
),

overlap_calc AS (
    SELECT
        b.prop_no,
        b.layer,
        b.building_id,
        q.quadrant,
        q.quadrant_id,
        q.quadrant_geom,
        q.frontage_length,
        q.quadrant_is_front_facing,
        ST_Area(b.geom) AS building_area,
        ST_Area(ST_Intersection(b.geom, q.quadrant_geom)) AS overlap_area,
        b.geom AS building_geom,
        ST_Centroid(b.geom) AS building_centroid
    FROM building_clip b
    JOIN frontage_rank q
      ON b.prop_no = q.prop_no
     AND ST_Intersects(b.geom, q.quadrant_geom)
),

detailed AS (
    SELECT
        prop_no, layer, building_id,
        quadrant, quadrant_id,
        frontage_length, quadrant_is_front_facing,
        overlap_area, building_area,
        CASE WHEN building_area > 0 THEN overlap_area / building_area ELSE 0 END AS pct_overlap,
        building_geom, building_centroid, quadrant_geom
    FROM overlap_calc
    WHERE overlap_area >= 60
),

quadrant_agg AS (
    SELECT
        q.prop_no,
        q.layer,
        q.quadrant,
        q.quadrant_id,
        MAX(q.frontage_length) AS frontage_length,
        BOOL_OR(q.quadrant_is_front_facing) AS quadrant_is_front_facing,
        COUNT(DISTINCT d.building_id) AS quadrant_building_count,
        COALESCE(SUM(d.building_area), 0) AS quadrant_total_building_area,
        COALESCE(SUM(d.overlap_area), 0) AS quadrant_total_overlap_area,

        CASE
            WHEN COUNT(d.building_id) = 0 AND MAX(q.frontage_length) > 0
            THEN TRUE ELSE FALSE
        END AS is_buildable_quadrant

    FROM frontage_rank q
    LEFT JOIN detailed d
      ON q.prop_no = d.prop_no
     AND q.layer = d.layer
     AND q.quadrant_id = d.quadrant_id
    GROUP BY q.prop_no, q.layer, q.quadrant, q.quadrant_id
),

final_data AS (
    SELECT
        qa.prop_no,
        qa.layer,
        d.building_id,
        qa.quadrant,
        qa.quadrant_id,
        qa.frontage_length,
        qa.quadrant_is_front_facing,
        qa.is_buildable_quadrant,
        d.pct_overlap,
        d.overlap_area,
        d.building_area,
        qa.quadrant_building_count,
        qa.quadrant_total_building_area,
        qa.quadrant_total_overlap_area,
        d.building_geom,
        d.building_centroid,
        q.quadrant_geom
    FROM quadrant_agg qa
    LEFT JOIN detailed d
      ON qa.prop_no = d.prop_no
     AND qa.layer = d.layer
     AND qa.quadrant_id = d.quadrant_id
    JOIN quadrant_parts q
      ON qa.prop_no = q.prop_no
     AND qa.layer = q.layer
     AND qa.quadrant_id = q.quadrant_id
)

SELECT
    ROW_NUMBER() OVER (ORDER BY prop_no, quadrant_id, building_id) AS fid,
    *
FROM final_data;

CREATE UNIQUE INDEX property_grz_ldcap_bqs_pk
ON property.property_grz_ldcap_building_quadrant_stats (fid);

CREATE INDEX property_grz_ldcap_bqs_geom_idx
ON property.property_grz_ldcap_building_quadrant_stats
USING GIST (building_geom);

CREATE INDEX property_grz_ldcap_bqs_quad_geom_idx
ON property.property_grz_ldcap_building_quadrant_stats
USING GIST (quadrant_geom);

CREATE INDEX property_grz_ldcap_bqs_prop_idx
ON property.property_grz_ldcap_building_quadrant_stats (prop_no);

CREATE INDEX property_grz_ldcap_bqs_layer_idx
ON property.property_grz_ldcap_building_quadrant_stats (layer);

DO
$do$
BEGIN
EXECUTE format($$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_building_quadrant_stats is 'Regenerated by Stored Procedure %s'$$, LOCALTIMESTAMP);
END
$do$
$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_stats()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_stats() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_stats() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_stats() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_stats() TO wdc_gisprod;

