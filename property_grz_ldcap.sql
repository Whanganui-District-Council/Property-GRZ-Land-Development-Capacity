-- PROCEDURE: property.create_mv_property_grz_ldcap()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap(
	)
LANGUAGE 'sql'
AS $BODY$


DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_summary_suburbs;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_summary;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_fully_developed;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_vacant_viable;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_infill_viable;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_fully_developed_testing;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_infill_viability_testing;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_vacant_viability_testing;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_viability_overlay_analysis;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_building_quadrant_summary;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_building_quadrant_stats;


CALL property.create_mv_property_grz_ldcap_building_quadrant_stats();
CALL property.create_mv_property_grz_ldcap_building_quadrant_summary();

CALL property.create_mv_property_grz_ldcap_viability_overlay_analysis();

CALL property.create_mv_property_grz_ldcap_infill_viability_testing();
CALL property.create_mv_property_grz_ldcap_vacant_viability_testing();
CALL property.create_mv_property_grz_ldcap_fully_developed_testing();

CALL property.create_mv_property_grz_ldcap_infill_viable();
CALL property.create_mv_property_grz_ldcap_vacant_viable();
CALL property.create_mv_property_grz_ldcap_fully_developed();

CALL property.create_mv_property_grz_ldcap_summary();
CALL property.create_mv_property_grz_ldcap_summary_suburbs();

$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap() TO wdc_gisprod;

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
      AND ST_Area(b.geom) >= (SELECT value_numeric FROM property.get_rule_record('min_building_area'))
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
    WHERE overlap_area >= (SELECT value_numeric FROM property.get_rule_record('min_building_area'))
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

-- PROCEDURE: property.create_mv_property_grz_ldcap_building_quadrant_summary()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap_building_quadrant_summary();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_summary(
	)
LANGUAGE 'sql'
AS $BODY$
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_building_quadrant_summary;

CREATE MATERIALIZED VIEW property.property_grz_ldcap_building_quadrant_summary AS
WITH base AS (
    SELECT *
    FROM property.property_grz_ldcap_building_quadrant_stats
),

agg AS (
    SELECT
        prop_no,
        layer,

        COUNT(DISTINCT building_id) AS total_buildings,
        SUM(building_area) AS total_building_area,

        SUM(CASE WHEN quadrant_id = 1 THEN quadrant_building_count ELSE 0 END) AS ne_count,
        SUM(CASE WHEN quadrant_id = 2 THEN quadrant_building_count ELSE 0 END) AS nw_count,
        SUM(CASE WHEN quadrant_id = 3 THEN quadrant_building_count ELSE 0 END) AS se_count,
        SUM(CASE WHEN quadrant_id = 4 THEN quadrant_building_count ELSE 0 END) AS sw_count,

        SUM(CASE WHEN is_buildable_quadrant THEN 1 ELSE 0 END) AS buildable_quadrant_count,

        MAX(
            CASE 
                WHEN quadrant_is_front_facing THEN quadrant_id 
                ELSE NULL 
            END
        ) AS front_facing_quadrant_id,

        MAX(frontage_length) AS max_frontage_length,
        SUM(frontage_length) AS total_frontage_length

    FROM base
    GROUP BY prop_no, layer
),

final AS (
    SELECT
        a.prop_no,
        a.layer,
        a.total_buildings,
        a.total_building_area,
        a.ne_count,
        a.nw_count,
        a.se_count,
        a.sw_count,
        a.buildable_quadrant_count,
        a.front_facing_quadrant_id,
        a.max_frontage_length,
        a.total_frontage_length,
        p.geom AS property_geom   -- ✅ added geometry at end
    FROM agg a
    JOIN property.property_eplan_zones p
      ON a.prop_no = p.prop_no
)

SELECT
    ROW_NUMBER() OVER (ORDER BY prop_no) AS fid,
    *
FROM final;

-- Primary key
CREATE UNIQUE INDEX property_grz_ldcap_bqs_summary_pk
ON property.property_grz_ldcap_building_quadrant_summary (fid);

-- Lookups
CREATE INDEX property_grz_ldcap_bqs_summary_prop_idx
ON property.property_grz_ldcap_building_quadrant_summary (prop_no);

CREATE INDEX property_grz_ldcap_bqs_summary_layer_idx
ON property.property_grz_ldcap_building_quadrant_summary (layer);

-- ✅ Spatial index for property geometry
CREATE INDEX property_grz_ldcap_bqs_summary_geom_idx
ON property.property_grz_ldcap_building_quadrant_summary
USING GIST (property_geom);

DO
$do$
BEGIN
EXECUTE format($$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_building_quadrant_summary is 'Regenerated by Stored Procedure %s'$$, LOCALTIMESTAMP);
END
$do$
$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_summary()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_summary() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_summary() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_summary() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_building_quadrant_summary() TO wdc_gisprod;

-- PROCEDURE: property.create_mv_property_grz_ldcap_fully_developed()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap_fully_developed();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_fully_developed(
	)
LANGUAGE 'sql'
AS $BODY$
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_fully_developed;

CREATE MATERIALIZED VIEW property.property_grz_ldcap_fully_developed
TABLESPACE pg_default
AS

WITH excl AS (
    -- 1a. Facilities: Health facilities, Rest Homes, Pensioner Housing, Schools, Campgrounds, Prisons, Justice Facilities, Marae, Religious Activities, Fuel Facilities 
    SELECT p.prop_no
    FROM property.property p
    CROSS JOIN (
        SELECT ST_Union(geom) AS geom 
        FROM general.whanganui_local_facilities
    ) wlf
    WHERE ST_Intersects(ST_PointOnSurface(p.geom), wlf.geom)

    UNION ALL

    -- 1b. Open Space Zone
    SELECT p.prop_no
    FROM property.property p
    CROSS JOIN (
        SELECT ST_Union(geom) AS geom 
        FROM eplan.osz_open_space_zone
    ) osz
    WHERE ST_Intersects(ST_PointOnSurface(p.geom), osz.geom)

    UNION ALL

    -- 2. Non-dominant GRZ
    SELECT prop_no
    FROM property.property_eplan_zones_multiples
    WHERE layer = 'grz_general_residential_zone'
      AND overlap < (SELECT value_numeric FROM property.get_rule_record('pct_multi_zone_dominance'))

	UNION ALL

	-- infill property
	SELECT prop_no
	FROM property.property_grz_ldcap_infill_viable

	UNION ALL

	-- vacant property
	SELECT prop_no
	FROM property.property_grz_ldcap_vacant_viable

)

,potential AS (
	SELECT 
		p.prop_no,
		'Fully Developed' AS potential_land_development_type,
		1 AS total_potential_lots,
		ROUND(ST_Area(p.geom)::numeric,3) As total_area_calc,
		p.geom
	FROM property.property_eplan_zones p
	WHERE p.layer = 'grz_general_residential_zone'
	AND NOT EXISTS (
	    SELECT 1 FROM excl e WHERE e.prop_no = p.prop_no
		)

)

SELECT row_number() OVER (ORDER BY p.prop_no) AS fid,
p.prop_no,
p.potential_land_development_type,
0 AS phu_yield,
p.total_area_calc / 10000 AS land_area_ha,
p.total_area_calc,
(SELECT total_road_frontage FROM property.property_grz_ldcap_viability_overlay_analysis qs WHERE p.prop_no = qs.prop_no) AS total_road_frontage,
p.geom
FROM potential p

WITH DATA;

ALTER TABLE property.property_grz_ldcap_fully_developed
    OWNER TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_fully_developed TO postgres;
GRANT ALL ON TABLE property.property_grz_ldcap_fully_developed TO wdc;
GRANT SELECT ON TABLE property.property_grz_ldcap_fully_developed TO wdc_gisprod;

CREATE INDEX property_grz_ldcap_fully_developed_fid_idx
    ON property.property_grz_ldcap_fully_developed USING btree
    (fid)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_fully_developed_prop_no_idx
    ON property.property_grz_ldcap_fully_developed USING btree
    (prop_no)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_fully_developed_geom_idx
    ON property.property_grz_ldcap_fully_developed USING gist
    (geom)
    TABLESPACE pg_default;
DO
$do$
BEGIN
EXECUTE format($$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_fully_developed is 'Regenerated by Stored Procedure %s'$$, LOCALTIMESTAMP);
END
$do$
$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap_fully_developed()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_fully_developed() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_fully_developed() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_fully_developed() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_fully_developed() TO wdc_gisprod;

-- PROCEDURE: property.create_mv_property_grz_ldcap_fully_developed_testing()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap_fully_developed_testing();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_fully_developed_testing(
	)
LANGUAGE 'sql'
AS $BODY$
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_fully_developed_testing;

CREATE MATERIALIZED VIEW property.property_grz_ldcap_fully_developed_testing
TABLESPACE pg_default
AS

-- ---------------------------------
-- Excluded properties
-- ---------------------------------
WITH excl AS (

SELECT DISTINCT prop_no
FROM (

    -- 1a. Facilities: Health facilities, Rest Homes, Pensioner Housing, Schools, Campgrounds, Prisons, Justice Facilities, Marae, Religious Activities, Fuel Facilities 
    SELECT p.prop_no
    FROM property.property p
    CROSS JOIN (
        SELECT ST_Union(geom) AS geom 
        FROM general.whanganui_local_facilities
    ) wlf
    WHERE ST_Intersects(ST_PointOnSurface(p.geom), wlf.geom)

    UNION ALL

    -- 1b. Open Space Zone
    SELECT p.prop_no
    FROM property.property p
    CROSS JOIN (
        SELECT ST_Union(geom) AS geom 
        FROM eplan.osz_open_space_zone
    ) osz
    WHERE ST_Intersects(ST_PointOnSurface(p.geom), osz.geom)

    UNION ALL

    -- 2. Non-dominant GRZ
    SELECT prop_no
    FROM property.property_eplan_zones_multiples
    WHERE layer = 'grz_general_residential_zone'
      AND overlap < (SELECT value_numeric FROM property.get_rule_record('pct_multi_zone_dominance'))

	UNION ALL

	-- infill property
	SELECT prop_no
	FROM property.property_grz_ldcap_infill_viability_testing

	UNION ALL

	-- vacant property
	SELECT prop_no
	FROM property.property_grz_ldcap_vacant_viability_testing

) ex
)

-- ---------------------------------
-- GRZ filtered properties
-- ---------------------------------
,pgrz AS (
SELECT p.prop_no, p.geom
FROM property.property_eplan_zones p
WHERE p.layer = 'grz_general_residential_zone'
AND NOT EXISTS (
    SELECT 1 FROM excl e WHERE e.prop_no = p.prop_no
)
)

-- ---------------------------------
-- Final output with property geometry and maximum inscribed circle geometry (building platform test)
-- ---------------------------------
SELECT 
    row_number() OVER (ORDER BY p.prop_no) AS fid,
    p.prop_no,
	'Developed' AS potential_land_development_type,
    mic.radius,
    ST_Area(ST_Buffer(mic.center, mic.radius, 50)) AS platform_area,
    ST_Buffer(mic.center, mic.radius, 50) AS platform_geom,
    p.geom

FROM pgrz p
CROSS JOIN LATERAL ST_MaximumInscribedCircle(p.geom) AS mic

WITH DATA;

ALTER TABLE property.property_grz_ldcap_fully_developed_testing
    OWNER TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_fully_developed_testing TO postgres;
GRANT ALL ON TABLE property.property_grz_ldcap_fully_developed_testing TO wdc;
GRANT SELECT ON TABLE property.property_grz_ldcap_fully_developed_testing TO wdc_gisprod;

CREATE INDEX property_grz_ldcap_fully_developed_testing_fid_idx
    ON property.property_grz_ldcap_fully_developed_testing USING btree
    (fid)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_fully_developed_testing_prop_no_idx
    ON property.property_grz_ldcap_fully_developed_testing USING btree
    (prop_no)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_fully_developed_testing_geom_idx
    ON property.property_grz_ldcap_fully_developed_testing USING gist
    (geom)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_fully_developed_testing_platform_geom_idx
    ON property.property_grz_ldcap_fully_developed_testing USING gist
    (platform_geom)
    TABLESPACE pg_default;
DO
$do$
BEGIN
EXECUTE format($$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_fully_developed_testing is 'Regenerated by Stored Procedure %s'$$, LOCALTIMESTAMP);
END
$do$
$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap_fully_developed_testing()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_fully_developed_testing() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_fully_developed_testing() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_fully_developed_testing() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_fully_developed_testing() TO wdc_gisprod;

-- PROCEDURE: property.create_mv_property_grz_ldcap_infill_viability_testing()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap_infill_viability_testing();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_infill_viability_testing(
	)
LANGUAGE 'sql'
AS $BODY$
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_infill_viability_testing;

CREATE MATERIALIZED VIEW property.property_grz_ldcap_infill_viability_testing
TABLESPACE pg_default
AS

-- ---------------------------------
-- Excluded properties
-- ---------------------------------
WITH excl AS (

SELECT DISTINCT prop_no
FROM (

    -- 1. Facilities
    SELECT p.prop_no
    FROM property.property p
    CROSS JOIN (
        SELECT ST_Union(geom) AS geom 
        FROM general.whanganui_local_facilities
    ) wlf
    WHERE ST_Intersects(ST_PointOnSurface(p.geom), wlf.geom)

    UNION ALL

    -- 1b. Open Space Zone
    SELECT p.prop_no
    FROM property.property p
    CROSS JOIN (
        SELECT ST_Union(geom) AS geom 
        FROM eplan.osz_open_space_zone
    ) osz
    WHERE ST_Intersects(ST_PointOnSurface(p.geom), osz.geom)

    UNION ALL

    -- 2. Non-dominant GRZ
    SELECT prop_no
    FROM property.property_eplan_zones_multiples
    WHERE layer = 'grz_general_residential_zone'
      AND overlap < (SELECT value_numeric FROM property.get_rule_record('pct_multi_zone_dominance'))

    UNION ALL

    -- 3. Undersized lots
    SELECT p.prop_no
    FROM property.property p
    WHERE ST_Area(p.geom) < 2 * CASE 
        WHEN EXISTS (
            SELECT 1 
            FROM property.property_eplan_overlays o 
            WHERE o.prop_no = p.prop_no 
              AND o.layer = (SELECT value_text FROM property.get_rule_record('eplan_overlay_layer'))
        ) THEN (SELECT value_numeric FROM property.get_rule_record('min_lot_size_overlay'))
        ELSE (SELECT value_numeric FROM property.get_rule_record('min_lot_size_standard'))
    END

    UNION ALL

    -- 4. Building coverage ≥25%
    SELECT p.prop_no
    FROM property.property p
    JOIN property.building_footprints_2025 b
      ON p.geom && b.geom
     AND ST_Intersects(p.geom, b.geom)
    WHERE b.status IS DISTINCT FROM 'Deleted'
      AND ST_Area(b.geom) >= (SELECT value_numeric FROM property.get_rule_record('min_building_area'))
    GROUP BY p.prop_no, p.geom
    HAVING 
        SUM(ST_Area(ST_Intersection(p.geom, b.geom))) / ST_Area(p.geom) >= (SELECT value_numeric FROM property.get_rule_record('max_building_coverage'))

    UNION ALL

    -- 5. Multi-property centroid conflict
    SELECT p.prop_no
    FROM property.property p
    JOIN property.property a
      ON a.geom && p.geom
     AND ST_Intersects(ST_PointOnSurface(ST_Buffer(a.geom, -0.3)), p.geom)
    GROUP BY p.prop_no, p.geom
    HAVING COUNT(a.fid) > 1

    UNION ALL

    -- 6. Property overlap >1% (optimised)
    SELECT DISTINCT ON (p1.prop_no) p1.prop_no
    FROM property.property p1
    JOIN property.property p2
      ON p1.prop_no <> p2.prop_no
     AND p1.geom && p2.geom
    WHERE 
        ST_Intersects(p1.geom, p2.geom)
        AND ST_Area(p1.geom) > 50
        AND ST_Area(p2.geom) > 50
        AND ST_Area(ST_Intersection(p1.geom, p2.geom)) > 5
        AND (
            ST_Area(ST_Intersection(p1.geom, p2.geom)) 
            / ST_Area(p1.geom)
        ) > 0.01

    UNION ALL

    -- 7. Multi-building + coverage >=25%
    SELECT p.prop_no
    FROM property.property p
    JOIN property.building_footprints_2025 b
      ON p.geom && b.geom
     AND ST_Intersects(p.geom, b.geom)
    WHERE 
        b.status IS DISTINCT FROM 'Deleted'
        AND ST_Area(b.geom) >= (SELECT value_numeric FROM property.get_rule_record('min_building_area'))
    GROUP BY p.prop_no, p.geom
    HAVING 
        COUNT(*) > 1
        AND (
            SUM(ST_Area(ST_Intersection(p.geom, b.geom))) 
            / ST_Area(p.geom)
        ) >= (SELECT value_numeric FROM property.get_rule_record('max_building_coverage'))

    UNION ALL

	-- Property Building Consents post 2025 Aerial Photos Building Footprints (NRD, MUR, RB, AR)
	SELECT prop_no
	FROM property.property_building_consents_dwellings_gt20250206

	UNION ALL

	-- no existing buildings
	SELECT qs.prop_no 
	FROM property.property_grz_ldcap_building_quadrant_summary qs 
	WHERE total_buildings = 0 

	UNION ALL

	-- known exclusions (mainly property with multiple small footprints)
	SELECT prop_no
	FROM property.property
	--WHERE prop_no IN (8075,8104,9692,33718,80750,2059,428,676,1394)
	WHERE prop_no = ANY(string_to_array((SELECT value_text FROM property.get_rule_record('infill_prop_no_exclusions')), ',')::int[])

) ex
)

-- ---------------------------------
-- GRZ filtered properties
-- ---------------------------------
,pgrz AS (
SELECT p.prop_no, p.geom
FROM property.property_eplan_zones p
WHERE p.layer = 'grz_general_residential_zone'
AND NOT EXISTS (
    SELECT 1 FROM excl e WHERE e.prop_no = p.prop_no
)
)

-- ---------------------------------
-- Building processing
-- ---------------------------------
, buildings_clipped AS (
SELECT 
    pgrz.prop_no,
    ST_CollectionExtract(ST_Intersection(b.geom, pgrz.geom), 3) AS geom
FROM property.building_footprints_2025 b
JOIN pgrz ON ST_Intersects(pgrz.geom, b.geom)
WHERE b.status IS DISTINCT FROM 'Deleted'
)

, buidlings AS (
SELECT prop_no, geom
FROM buildings_clipped
WHERE ST_Area(geom) >= (SELECT value_numeric FROM property.get_rule_record('min_building_area'))
)

-- ---------------------------------
-- Setback analysis
-- ---------------------------------
,building_setback AS (
SELECT 
    buidlings.prop_no,
    b_seg.path AS building_segment_id,
    p_seg.path AS property_segment_id,
    ST_Length(ST_ShortestLine(b_seg.geom, p_seg.geom)) AS shortest_distance
FROM buidlings
JOIN pgrz ON buidlings.prop_no = pgrz.prop_no
CROSS JOIN LATERAL ST_DumpSegments(ST_Boundary(buidlings.geom)) b_seg
CROSS JOIN LATERAL (
    SELECT p_dump.path, p_dump.geom
    FROM ST_DumpSegments(ST_Boundary(pgrz.geom)) p_dump
    WHERE 
        ST_LineLocatePoint(
            p_dump.geom,
            ST_ClosestPoint(p_dump.geom, b_seg.geom)
        ) BETWEEN 0.001 AND 0.999
	AND NOT EXISTS (
		SELECT 1
			FROM property.property_road_frontage rf2
			CROSS JOIN LATERAL ST_DumpSegments(rf2.geom) rf_seg(path, geom)
			WHERE rf2.prop_no = buidlings.prop_no
			AND ST_Equals(p_dump.geom, rf_seg.geom)
	)

		
    ORDER BY b_seg.geom <-> p_dump.geom
    LIMIT 1
) p_seg
)

-- ---------------------------------
-- Access check
-- ---------------------------------
, property_side_distance AS (
SELECT prop_no, property_segment_id,
       MIN(shortest_distance) AS closest_dist
FROM building_setback
GROUP BY prop_no, property_segment_id
)

, property_side_compliance AS (
SELECT prop_no,
       COUNT(*) FILTER (WHERE closest_dist >= (SELECT value_numeric FROM property.get_rule_record('min_side_access'))) AS clean_access_sides_count
FROM property_side_distance
GROUP BY prop_no
)

-- ---------------------------------
-- Building union
-- ---------------------------------
, property_buildings AS (
SELECT pgrz.prop_no, ST_Union(buidlings.geom) AS geom
FROM pgrz
JOIN buidlings ON pgrz.prop_no = buidlings.prop_no
GROUP BY pgrz.prop_no
)

-- ---------------------------------
-- Remove overlay restrictions
-- ---------------------------------
, dor AS (
SELECT dprf.prop_no,
       CASE 
           WHEN oa.overlay_geom IS NOT NULL 
           THEN ST_Difference(dprf.geom, oa.overlay_geom)
           ELSE dprf.geom
       END AS geom
FROM pgrz AS dprf
LEFT JOIN property.property_grz_ldcap_viability_overlay_analysis oa ON dprf.prop_no = oa.prop_no
)

-- ---------------------------------
-- Remove buildings
-- ---------------------------------
, dp AS (
SELECT dor.prop_no,
       CASE 
           WHEN ipb.geom IS NOT NULL 
           THEN ST_Difference(dor.geom, ST_Buffer(ipb.geom, (SELECT value_numeric FROM property.get_rule_record('min_building_distance'))))
           ELSE dor.geom
       END AS geom
FROM dor
LEFT JOIN property_buildings ipb ON dor.prop_no = ipb.prop_no
)




-- ---------------------------------
-- Final Infill output with MIC test for building platform
-- ---------------------------------
SELECT 
    row_number() OVER ()::integer AS fid,
    dp.prop_no,
	'Infill' AS potential_land_development_type,
    mic.radius,
    ST_Area(ST_Buffer(mic.center, mic.radius, 50)) AS platform_area,
    ST_Buffer(mic.center, mic.radius, 50) AS platform_geom,
    p.geom

FROM dp
JOIN property.property p ON p.prop_no = dp.prop_no
CROSS JOIN LATERAL ST_MaximumInscribedCircle(dp.geom) AS mic
WHERE mic.radius >= (SELECT value_numeric FROM property.get_rule_record('min_mic_radius'))
AND (
    ST_Area(p.geom) - ST_Area(dp.geom) + (PI() * ((SELECT value_numeric FROM property.get_rule_record('min_mic_radius')) ^ 2))
	) > ((SELECT value_numeric FROM property.get_rule_record('min_lot_open_space')) * 2)
AND (
		dp.prop_no IN (
	    SELECT prop_no 
	    FROM property_side_compliance 
	    WHERE clean_access_sides_count >= 1
		)
		OR
	    (
        -- Case 2: building overlap < 5% of property area
        dp.prop_no IN (
            SELECT p.prop_no
            FROM pgrz p
            JOIN property_buildings b ON p.prop_no = b.prop_no
            GROUP BY p.prop_no, p.geom
            HAVING 
                SUM(ST_Area(ST_Intersection(b.geom, p.geom))) 
                / NULLIF(ST_Area(p.geom), 0) < 0.05
        	)
    	)
		OR
		(
		-- Case 3: catch edge cases where building is predominantly at back of property allowing for building in front
		dp.prop_no IN (
			SELECT q.prop_no
            FROM property.property_grz_ldcap_building_quadrant_stats q
			WHERE quadrant_is_front_facing
			AND is_buildable_quadrant
			AND frontage_length >= (SELECT value_numeric FROM property.get_rule_record('min_frontage_quadrant'))
			)
		)
	)

	

	
	
WITH DATA;

ALTER TABLE property.property_grz_ldcap_infill_viability_testing
    OWNER TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_infill_viability_testing TO postgres;
GRANT ALL ON TABLE property.property_grz_ldcap_infill_viability_testing TO wdc;
GRANT SELECT ON TABLE property.property_grz_ldcap_infill_viability_testing TO wdc_gisprod;

CREATE INDEX property_grz_ldcap_infill_testing_fid_idx
    ON property.property_grz_ldcap_infill_viability_testing USING btree
    (fid)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_infill_testing_prop_no_idx
    ON property.property_grz_ldcap_infill_viability_testing USING btree
    (prop_no)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_infill_testing_geom_idx
    ON property.property_grz_ldcap_infill_viability_testing USING gist
    (geom)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_infill_testing_platform_geom_idx
    ON property.property_grz_ldcap_infill_viability_testing USING gist
    (platform_geom)
    TABLESPACE pg_default;
DO
$do$
BEGIN
EXECUTE format($$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_infill_viability_testing is 'Regenerated by Stored Procedure %s'$$, LOCALTIMESTAMP);
END
$do$
$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap_infill_viability_testing()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_infill_viability_testing() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_infill_viability_testing() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_infill_viability_testing() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_infill_viability_testing() TO wdc_gisprod;

-- PROCEDURE: property.create_mv_property_grz_ldcap_infill_viable()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap_infill_viable();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_infill_viable(
	)
LANGUAGE 'sql'
AS $BODY$
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_infill_viable;

CREATE MATERIALIZED VIEW property.property_grz_ldcap_infill_viable
TABLESPACE pg_default
AS



WITH base AS (
    SELECT 
        prop_no,
		developable_area,
        to_jsonb(p) AS js
    FROM property.property_grz_ldcap_viability_overlay_analysis p
),

excl AS (
    SELECT DISTINCT b.prop_no
    FROM base b
    JOIN property.property_grz_ldcap_exclusion_thresholds t
        ON TRUE
    WHERE
        (
            t.operator = '>'
            AND (b.js ->> t.source_column)::numeric > t.threshold
        ) OR
        (
            t.operator = '>='
            AND (b.js ->> t.source_column)::numeric >= t.threshold
        ) OR
        (
            t.operator = '<'
            AND (b.js ->> t.source_column)::numeric < t.threshold
        ) OR
        (
            t.operator = '<='
            AND (b.js ->> t.source_column)::numeric <= t.threshold
        ) OR
        (
            t.operator = '='
            AND (b.js ->> t.source_column)::numeric = t.threshold
        ) OR
        (
            t.operator = 'BETWEEN'
            AND (b.js ->> t.source_column)::numeric 
                BETWEEN t.threshold_min AND t.threshold_max
        )
),

potential AS (
    SELECT 
        p.prop_no,
        p.potential_land_development_type,
        CASE 
            WHEN EXISTS (
                SELECT 1 
                FROM property.property_eplan_overlays o 
                WHERE o.prop_no = p.prop_no 
                  AND o.layer = (SELECT value_text FROM property.get_rule_record('eplan_overlay_layer'))
            ) THEN FLOOR(b.developable_area / (SELECT value_numeric FROM property.get_rule_record('min_lot_size_overlay')))
            ELSE FLOOR(b.developable_area / (SELECT value_numeric FROM property.get_rule_record('min_lot_size_standard')))
        END AS total_potential_lots,
        ROUND(ST_Area(p.geom)::numeric, 3) AS total_area_calc,
		(SELECT total_road_frontage FROM property.property_grz_ldcap_viability_overlay_analysis qs WHERE p.prop_no = qs.prop_no) AS total_road_frontage,
        p.geom
        
    FROM property.property_grz_ldcap_infill_viability_testing p
	CROSS JOIN LATERAL (SELECT * FROM base WHERE p.prop_no = prop_no) AS b
    WHERE 
	NOT EXISTS (
        SELECT 1 
        FROM excl e 
        WHERE e.prop_no = p.prop_no
    )
)



SELECT row_number() OVER (ORDER BY p.prop_no) AS fid,
p.prop_no,
p.potential_land_development_type,
CASE
	 WHEN p.total_potential_lots = 1 THEN 0
	 WHEN p.total_potential_lots BETWEEN 2 AND 6 THEN total_potential_lots - 1
	 WHEN p.total_potential_lots >= 7 AND p.total_road_frontage >= (SELECT value_numeric FROM property.get_rule_record('min_frontage_large_scale')) THEN FLOOR(total_potential_lots-1 * ((SELECT value_numeric FROM property.get_rule_record('pct_large_scale_efficiency'))/100))
	 WHEN p.total_potential_lots >= 7 AND p.total_road_frontage < (SELECT value_numeric FROM property.get_rule_record('min_frontage_large_scale')) THEN 6 -- fallback when access is not wide enough
	 ELSE 0
END AS phu_yield,
p.total_area_calc / 10000 AS land_area_ha,
p.total_area_calc,
p.total_road_frontage,
p.geom
FROM potential p
WHERE 
CASE
    WHEN p.total_potential_lots >= 7 AND p.total_road_frontage >= (SELECT value_numeric FROM property.get_rule_record('min_frontage_large_scale')) THEN p.total_road_frontage >= (SELECT value_numeric FROM property.get_rule_record('min_frontage_large_scale'))
	WHEN p.total_potential_lots >= 7 AND p.total_road_frontage < (SELECT value_numeric FROM property.get_rule_record('min_frontage_large_scale')) THEN p.total_road_frontage >= (SELECT value_numeric FROM property.get_rule_record('min_frontage_general')) -- fallback when access is not wide enough
    ELSE p.total_road_frontage >= (SELECT value_numeric FROM property.get_rule_record('min_frontage_general'))
END
AND p.total_potential_lots > 1


WITH DATA;

ALTER TABLE property.property_grz_ldcap_infill_viable
    OWNER TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_infill_viable TO postgres;
GRANT ALL ON TABLE property.property_grz_ldcap_infill_viable TO wdc;
GRANT SELECT ON TABLE property.property_grz_ldcap_infill_viable TO wdc_gisprod;

CREATE INDEX property_grz_ldcap_infill_viable_fid_idx
    ON property.property_grz_ldcap_infill_viable USING btree
    (fid)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_infill_viable_prop_no_idx
    ON property.property_grz_ldcap_infill_viable USING btree
    (prop_no)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_infill_viable_geom_idx
    ON property.property_grz_ldcap_infill_viable USING gist
    (geom)
    TABLESPACE pg_default;
DO
$do$
BEGIN
EXECUTE format($$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_infill_viable is 'Regenerated by Stored Procedure %s'$$, LOCALTIMESTAMP);
END
$do$
$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap_infill_viable()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_infill_viable() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_infill_viable() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_infill_viable() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_infill_viable() TO wdc_gisprod;

-- PROCEDURE: property.create_mv_property_grz_ldcap_summary()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap_summary();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_summary(
	)
LANGUAGE 'sql'
AS $BODY$


DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_summary;

CREATE MATERIALIZED VIEW property.property_grz_ldcap_summary
TABLESPACE pg_default
AS

WITH developable AS (
    SELECT 
        prop_no,
        potential_land_development_type,
        phu_yield,
        phu_yield AS developable_lots,
        land_area_ha,
        total_road_frontage,
        CASE
            WHEN phu_yield = 1 THEN 'Single Vacant Lot'
            WHEN phu_yield BETWEEN 2 AND 6 THEN 'Small Scale Development'
            WHEN phu_yield >= 7 THEN 'Large Scale Development'
        END AS development_category
    FROM property.property_grz_ldcap_vacant_viable
    
    UNION ALL
    
    SELECT 
        prop_no,
        potential_land_development_type,
        phu_yield,
        phu_yield AS developable_lots,
        land_area_ha,
        total_road_frontage,
        CASE
            WHEN phu_yield = 1 THEN 'Single Lot Infill'
            WHEN phu_yield BETWEEN 2 AND 6 THEN 'Small Scale Infill'
            WHEN phu_yield >= 7 THEN 'Large Scale Infill'
        END AS development_category 
    FROM property.property_grz_ldcap_infill_viable
)

, summary AS (
SELECT
    potential_land_development_type,
    development_category,
    COUNT(*) AS developable_properties,
    SUM(developable_lots) AS total_developable_lots,
    SUM(phu_yield) AS total_phu_yield,
    SUM(land_area_ha) AS total_land_area_ha
FROM developable
GROUP BY 
    potential_land_development_type,
    development_category
ORDER BY 
    potential_land_development_type,
    development_category
)

SELECT row_number() OVER ()::integer AS fid,
*,
ST_GeomFromText('MULTIPOLYGON EMPTY', 2193)::geometry(MultiPolygon, 2193) AS geom
FROM summary




	

WITH DATA;

ALTER TABLE property.property_grz_ldcap_summary
    OWNER TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_summary TO postgres;
GRANT ALL ON TABLE property.property_grz_ldcap_summary TO wdc;
GRANT SELECT ON TABLE property.property_grz_ldcap_summary TO wdc_gisprod;


DO
$do$
BEGIN
EXECUTE format($$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_summary is 'Regenerated by Stored Procedure %s'$$, LOCALTIMESTAMP);
END
$do$
$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap_summary()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_summary() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_summary() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_summary() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_summary() TO wdc_gisprod;

-- PROCEDURE: property.create_mv_property_grz_ldcap_summary_suburbs()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap_summary_suburbs();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_summary_suburbs(
	)
LANGUAGE 'sql'
AS $BODY$


DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_summary_suburbs;

CREATE MATERIALIZED VIEW property.property_grz_ldcap_summary_suburbs
TABLESPACE pg_default
AS

WITH developable AS (
    SELECT 
        prop_no,
        potential_land_development_type,
        phu_yield,
        phu_yield AS developable_lots,
        land_area_ha,
        total_road_frontage,
        geom,
        CASE
            WHEN phu_yield = 1 THEN 'Single Vacant Lot'
            WHEN phu_yield BETWEEN 2 AND 6 THEN 'Small Scale Development'
            WHEN phu_yield >= 7 THEN 'Large Scale Development'
        END AS development_category
    FROM property.property_grz_ldcap_vacant_viable
    
    UNION ALL
    
    SELECT 
        prop_no,
        potential_land_development_type,
        phu_yield,
        phu_yield AS developable_lots,
        land_area_ha,
        total_road_frontage,
        geom,
        CASE
            WHEN phu_yield = 1 THEN 'Single Lot Infill'
            WHEN phu_yield BETWEEN 2 AND 6 THEN 'Small Scale Infill'
            WHEN phu_yield >= 7 THEN 'Large Scale Infill'
        END AS development_category 
    FROM property.property_grz_ldcap_infill_viable
),

developable_with_suburb AS (
    SELECT
        d.*,
        s.sa22023_v1_00_name_ascii AS suburb_name
    FROM developable d
    LEFT JOIN stats.wdc_2023_census_housing_data_by_sa2_clipped s
        ON ST_Within(
            ST_PointOnSurface(d.geom),
            s.geom
        )
),

summary AS (
    SELECT
        suburb_name,
        potential_land_development_type,
        development_category,
        COUNT(*) AS developable_properties,
        SUM(developable_lots) AS total_developable_lots,
        SUM(phu_yield) AS total_phu_yield,
        SUM(land_area_ha) AS total_land_area_ha
    FROM developable_with_suburb
    GROUP BY 
        suburb_name,
        potential_land_development_type,
        development_category
)

SELECT 
    row_number() OVER ()::integer AS fid,
    *,
    ST_GeomFromText('MULTIPOLYGON EMPTY', 2193)::geometry(MultiPolygon, 2193) AS geom
FROM summary
ORDER BY 
    suburb_name,
    potential_land_development_type,
    development_category



	

WITH DATA;

ALTER TABLE property.property_grz_ldcap_summary_suburbs
    OWNER TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_summary_suburbs TO postgres;
GRANT ALL ON TABLE property.property_grz_ldcap_summary_suburbs TO wdc;
GRANT SELECT ON TABLE property.property_grz_ldcap_summary_suburbs TO wdc_gisprod;


DO
$do$
BEGIN
EXECUTE format($$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_summary_suburbs is 'Regenerated by Stored Procedure %s'$$, LOCALTIMESTAMP);
END
$do$
$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap_summary_suburbs()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_summary_suburbs() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_summary_suburbs() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_summary_suburbs() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_summary_suburbs() TO wdc_gisprod;

-- PROCEDURE: property.create_mv_property_grz_ldcap_vacant_viability_testing()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap_vacant_viability_testing();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_vacant_viability_testing(
	)
LANGUAGE 'sql'
AS $BODY$
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_vacant_viability_testing;

CREATE MATERIALIZED VIEW property.property_grz_ldcap_vacant_viability_testing
TABLESPACE pg_default
AS

-- ---------------------------------
-- Excluded properties
-- ---------------------------------
WITH excl AS (

SELECT DISTINCT prop_no
FROM (

    -- 1a. Facilities: Health facilities, Rest Homes, Pensioner Housing, Schools, Campgrounds, Prisons, Justice Facilities, Marae, Religious Activities, Fuel Facilities 
    SELECT p.prop_no
    FROM property.property p
    CROSS JOIN (
        SELECT ST_Union(geom) AS geom 
        FROM general.whanganui_local_facilities
    ) wlf
    WHERE ST_Intersects(ST_PointOnSurface(p.geom), wlf.geom)

    UNION ALL

    -- 1b. Open Space Zone
    SELECT p.prop_no
    FROM property.property p
    CROSS JOIN (
        SELECT ST_Union(geom) AS geom 
        FROM eplan.osz_open_space_zone
    ) osz
    WHERE ST_Intersects(ST_PointOnSurface(p.geom), osz.geom)

    UNION ALL

    -- 2. Non-dominant GRZ
    SELECT prop_no
    FROM property.property_eplan_zones_multiples
    WHERE layer = 'grz_general_residential_zone'
      AND overlap < (SELECT value_numeric FROM property.get_rule_record('pct_multi_zone_dominance'))

    UNION ALL

    -- 3. Undersized lots
    SELECT p.prop_no
    FROM property.property p
    WHERE ST_Area(p.geom) < CASE 
        WHEN EXISTS (
            SELECT 1 
            FROM property.property_eplan_overlays o 
            WHERE o.prop_no = p.prop_no 
              AND o.layer = (SELECT value_text FROM property.get_rule_record('eplan_overlay_layer'))
        ) THEN (SELECT value_numeric FROM property.get_rule_record('min_lot_size_overlay'))
        ELSE (SELECT value_numeric FROM property.get_rule_record('min_lot_size_standard'))
    END

    UNION ALL

    -- 5. Multi-property centroid conflict
    SELECT p.prop_no
    FROM property.property p
    JOIN property.property a
      ON a.geom && p.geom
     AND ST_Intersects(ST_PointOnSurface(ST_Buffer(a.geom, -0.3)), p.geom)
    GROUP BY p.prop_no, p.geom
    HAVING COUNT(a.fid) > 1

    UNION ALL

    -- 6. Property overlap >1% (optimised)
    SELECT DISTINCT ON (p1.prop_no) p1.prop_no
    FROM property.property p1
    JOIN property.property p2
      ON p1.prop_no <> p2.prop_no
     AND p1.geom && p2.geom
    WHERE 
        ST_Intersects(p1.geom, p2.geom)
        AND ST_Area(p1.geom) > 50
        AND ST_Area(p2.geom) > 50
        AND ST_Area(ST_Intersection(p1.geom, p2.geom)) > 5
        AND (
            ST_Area(ST_Intersection(p1.geom, p2.geom)) 
            / ST_Area(p1.geom)
        ) > 0.01

	UNION ALL

	-- Property Building Consents post 2025 Aerial Photos Building Footprints (NRD, MUR, RB, AR)
	SELECT prop_no
	FROM property.property_building_consents_dwellings_gt20250206

	UNION ALL

	-- known exclusions
	SELECT prop_no
	FROM property.property
	--WHERE prop_no IN (8075,8104,9692,33718,80750,2059,428,676,1394,46750)
	--WHERE prop_no = ANY(string_to_array(property.get_rule_record('vacant_prop_no_exclusions')::int[])
	WHERE prop_no = ANY(string_to_array((SELECT value_text FROM property.get_rule_record('vacant_prop_no_exclusions')), ',')::int[])

) ex
)

-- ---------------------------------
-- GRZ filtered properties
-- ---------------------------------
,pgrz AS (
SELECT p.prop_no, p.geom
FROM property.property_grz_ldcap_viability_overlay_analysis p
WHERE p.is_vacant = true
AND NOT EXISTS (
    SELECT 1 FROM excl e WHERE e.prop_no = p.prop_no
)
)


-- ---------------------------------
-- Remove overlay restrictions
-- ---------------------------------
, dor AS (
SELECT dprf.prop_no,
       CASE 
           WHEN oa.overlay_geom IS NOT NULL 
           THEN ST_Difference(dprf.geom, oa.overlay_geom)
           ELSE dprf.geom
       END AS geom
FROM pgrz AS dprf
LEFT JOIN property.property_grz_ldcap_viability_overlay_analysis oa ON dprf.prop_no = oa.prop_no
)



-- ---------------------------------
-- Final output with property geometry and maximum inscribed circle geometry (building platform test)
-- ---------------------------------
SELECT 
    row_number() OVER ()::integer AS fid,
    dor.prop_no,
	'Vacant' AS potential_land_development_type,
    mic.radius,
    ST_Area(ST_Buffer(mic.center, mic.radius, 50)) AS platform_area,
    ST_Buffer(mic.center, mic.radius, 50) AS platform_geom,
    p.geom

FROM dor
JOIN property.property p ON p.prop_no = dor.prop_no
CROSS JOIN LATERAL ST_MaximumInscribedCircle(dor.geom) AS mic
WHERE mic.radius >= (SELECT value_numeric FROM property.get_rule_record('min_mic_radius'))
AND (
    ST_Area(p.geom) - ST_Area(dor.geom) + (PI() * ((SELECT value_numeric FROM property.get_rule_record('min_mic_radius')) ^ 2))
	) > (SELECT value_numeric FROM property.get_rule_record('min_lot_open_space'))





WITH DATA;

ALTER TABLE property.property_grz_ldcap_vacant_viability_testing
    OWNER TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_vacant_viability_testing TO postgres;
GRANT ALL ON TABLE property.property_grz_ldcap_vacant_viability_testing TO wdc;
GRANT SELECT ON TABLE property.property_grz_ldcap_vacant_viability_testing TO wdc_gisprod;

CREATE INDEX property_grz_ldcap_vacant_testing_fid_idx
    ON property.property_grz_ldcap_vacant_viability_testing USING btree
    (fid)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_vacant_testing_prop_no_idx
    ON property.property_grz_ldcap_vacant_viability_testing USING btree
    (prop_no)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_vacant_testing_geom_idx
    ON property.property_grz_ldcap_vacant_viability_testing USING gist
    (geom)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_vacant_testing_platform_geom_idx
    ON property.property_grz_ldcap_vacant_viability_testing USING gist
    (platform_geom)
    TABLESPACE pg_default;
DO
$do$
BEGIN
EXECUTE format($$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_vacant_viability_testing is 'Regenerated by Stored Procedure %s'$$, LOCALTIMESTAMP);
END
$do$
$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap_vacant_viability_testing()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_vacant_viability_testing() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_vacant_viability_testing() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_vacant_viability_testing() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_vacant_viability_testing() TO wdc_gisprod;

-- PROCEDURE: property.create_mv_property_grz_ldcap_vacant_viable()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap_vacant_viable();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_vacant_viable(
	)
LANGUAGE 'sql'
AS $BODY$
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_vacant_viable;

CREATE MATERIALIZED VIEW property.property_grz_ldcap_vacant_viable
TABLESPACE pg_default
AS



WITH base AS (
    SELECT 
        prop_no,
		developable_area,
        to_jsonb(p) AS js
    FROM property.property_grz_ldcap_viability_overlay_analysis p
),

excl AS (
    SELECT DISTINCT b.prop_no
    FROM base b
    JOIN property.property_grz_ldcap_exclusion_thresholds t
        ON TRUE
    WHERE
        (
            t.operator = '>'
            AND (b.js ->> t.source_column)::numeric > t.threshold
        ) OR
        (
            t.operator = '>='
            AND (b.js ->> t.source_column)::numeric >= t.threshold
        ) OR
        (
            t.operator = '<'
            AND (b.js ->> t.source_column)::numeric < t.threshold
        ) OR
        (
            t.operator = '<='
            AND (b.js ->> t.source_column)::numeric <= t.threshold
        ) OR
        (
            t.operator = '='
            AND (b.js ->> t.source_column)::numeric = t.threshold
        ) OR
        (
            t.operator = 'BETWEEN'
            AND (b.js ->> t.source_column)::numeric 
                BETWEEN t.threshold_min AND t.threshold_max
        )
),
potential AS (
	SELECT 
		p.prop_no,
		p.potential_land_development_type,
		CASE 
	        WHEN EXISTS (
	            SELECT 1 
	            FROM property.property_eplan_overlays o 
	            WHERE o.prop_no = p.prop_no 
                  AND o.layer = (SELECT value_text FROM property.get_rule_record('eplan_overlay_layer'))
            ) THEN FLOOR(b.developable_area / (SELECT value_numeric FROM property.get_rule_record('min_lot_size_overlay')))
            ELSE FLOOR(b.developable_area / (SELECT value_numeric FROM property.get_rule_record('min_lot_size_standard')))
		END AS total_potential_lots,
		ROUND(ST_Area(p.geom)::numeric,3) As total_area_calc,
		(SELECT total_road_frontage FROM property.property_grz_ldcap_viability_overlay_analysis qs WHERE p.prop_no = qs.prop_no) AS total_road_frontage,
		p.geom
		
	FROM property.property_grz_ldcap_vacant_viability_testing p
	CROSS JOIN LATERAL (SELECT * FROM base WHERE p.prop_no = prop_no) AS b
	WHERE
		NOT EXISTS (
	    	SELECT 1 FROM excl e WHERE e.prop_no = p.prop_no
		)
)

SELECT row_number() OVER (ORDER BY p.prop_no) AS fid,
p.prop_no,
p.potential_land_development_type,
CASE
	 WHEN p.total_potential_lots = 1 THEN 1
	 WHEN p.total_potential_lots BETWEEN 2 AND 6 THEN total_potential_lots
	 WHEN p.total_potential_lots >= 7 AND p.total_road_frontage >= (SELECT value_numeric FROM property.get_rule_record('min_frontage_large_scale')) THEN FLOOR(total_potential_lots * ((SELECT value_numeric FROM property.get_rule_record('pct_large_scale_efficiency'))/100))
	 WHEN p.total_potential_lots >= 7 AND p.total_road_frontage < (SELECT value_numeric FROM property.get_rule_record('min_frontage_large_scale')) THEN 6 -- fallback when access is not wide enough
	 ELSE 0
END AS phu_yield,
p.total_area_calc / 10000 AS land_area_ha,
p.total_area_calc,
(SELECT total_road_frontage FROM property.property_grz_ldcap_viability_overlay_analysis qs WHERE p.prop_no = qs.prop_no) AS total_road_frontage,
p.geom
FROM potential p
WHERE 
CASE
    WHEN p.total_potential_lots >= 7 AND p.total_road_frontage >= (SELECT value_numeric FROM property.get_rule_record('min_frontage_large_scale')) THEN p.total_road_frontage >= (SELECT value_numeric FROM property.get_rule_record('min_frontage_large_scale'))
	WHEN p.total_potential_lots >= 7 AND p.total_road_frontage < (SELECT value_numeric FROM property.get_rule_record('min_frontage_large_scale')) THEN p.total_road_frontage >= (SELECT value_numeric FROM property.get_rule_record('min_frontage_general')) -- fallback when access is not wide enough
    ELSE p.total_road_frontage >= (SELECT value_numeric FROM property.get_rule_record('min_frontage_general'))
END
AND p.total_potential_lots > 0





WITH DATA;

ALTER TABLE property.property_grz_ldcap_vacant_viable
    OWNER TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_vacant_viable TO postgres;
GRANT ALL ON TABLE property.property_grz_ldcap_vacant_viable TO wdc;
GRANT SELECT ON TABLE property.property_grz_ldcap_vacant_viable TO wdc_gisprod;

CREATE INDEX property_grz_ldcap_vacant_viable_fid_idx
    ON property.property_grz_ldcap_vacant_viable USING btree
    (fid)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_vacant_viable_prop_no_idx
    ON property.property_grz_ldcap_vacant_viable USING btree
    (prop_no)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_vacant_viable_geom_idx
    ON property.property_grz_ldcap_vacant_viable USING gist
    (geom)
    TABLESPACE pg_default;
DO
$do$
BEGIN
EXECUTE format($$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_vacant_viable is 'Regenerated by Stored Procedure %s'$$, LOCALTIMESTAMP);
END
$do$
$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap_vacant_viable()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_vacant_viable() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_vacant_viable() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_vacant_viable() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_vacant_viable() TO wdc_gisprod;

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis()
LANGUAGE plpgsql
AS $BODY$
DECLARE
    dyn_cols TEXT;
    sql TEXT;
BEGIN

-- ---------------------------------
-- Dynamic column builder
-- ---------------------------------
SELECT string_agg(
    format(
        'MAX(cfg.overlap_area) FILTER (WHERE cfg.alias = %L) AS prop_overlap_area_%s,
         MAX(cfg.overlap_pct)  FILTER (WHERE cfg.alias = %L) AS prop_overlap_pct_%s',
        alias, alias, alias, alias
    ),
    E',\n'
    ORDER BY sort_order
)
INTO dyn_cols
FROM property.property_grz_ldcap_overlay_analysis_config;

-- ---------------------------------
-- Main SQL
-- ---------------------------------
sql := format($sql$

DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_viability_overlay_analysis;

CREATE MATERIALIZED VIEW property.property_grz_ldcap_viability_overlay_analysis
AS

WITH pgrz AS (
    SELECT 
        p.prop_no,
        ST_Transform(p.geom, 2193) AS geom
    FROM property.property_eplan_zones p
    WHERE p.layer = 'grz_general_residential_zone'
)

SELECT 
    row_number() OVER (ORDER BY p.prop_no) AS fid,
    p.prop_no,

    ST_Area(p.geom) AS prop_area,

    -- ✅ dynamic overlay columns
    %s,

    -- Building footprints
    bf.overlap_area AS prop_overlap_area_building_footprints_2025_geq60,
    bf.overlap_pct  AS prop_overlap_pct_building_footprints_2025_geq60,

    -- Overlay
    cfg.overlay_geom,
    ST_Area(cfg.overlay_geom) AS overlay_area_total,
    ST_Area(cfg.overlay_geom) / ST_Area(p.geom) * 100 AS overlay_pct_total,

    -- Developable
    dev.developable_geom,
    dev.developable_area,
    dev.developable_pct,

    -- Attributes
    rf.total_road_frontage,
    vac.is_vacant,

    p.geom

FROM pgrz p

-- ---------------------------------
-- ✅ SINGLE PASS OVERLAY ENGINE
-- ---------------------------------
CROSS JOIN LATERAL (

    -- Step 1: compute all overlap rows ONCE
    WITH cfg_rows AS (
        SELECT
            c.alias,
            c.include_in_overlay,
            r.overlap_area,
            r.overlap_pct,
            r.overlap_geom
        FROM property.property_grz_ldcap_overlay_analysis_config c
        CROSS JOIN LATERAL general.calc_overlap_stats_record(
            p.geom,
            c.schema_name,
            c.table_name,
            c.filter_sql
        ) r
    ),

    -- Step 2: aggregate overlay geometry ONCE
    overlay AS (
        SELECT ST_Multi(
            ST_UnaryUnion(
                ST_Collect(overlap_geom)
            )
        ) AS overlay_geom
        FROM cfg_rows
        WHERE include_in_overlay
    )

    -- Step 3: return rows + overlay geom attached
    SELECT
        r.alias,
        r.overlap_area,
        r.overlap_pct,
        o.overlay_geom
    FROM cfg_rows r
    CROSS JOIN overlay o

) cfg

-- ---------------------------------
-- ✅ Developable (reuses overlay)
-- ---------------------------------
CROSS JOIN LATERAL (
    SELECT
        g AS developable_geom,
        ST_Area(g) AS developable_area,
        ST_Area(g) / ST_Area(p.geom) * 100 AS developable_pct
    FROM (
        SELECT ST_Multi(
            ST_Difference(p.geom, cfg.overlay_geom)
        ) AS g
    ) t
) dev

-- ---------------------------------
-- Building footprints
-- ---------------------------------
CROSS JOIN LATERAL general.calc_overlap_stats_record(
    p.geom,
    'property',
    'building_footprints_2025',
    'ST_Area(geom) >= ' || (SELECT value_numeric FROM property.get_rule_record('min_building_area')) || ' AND status IS DISTINCT FROM ''Deleted'''
) bf

-- Road frontage
CROSS JOIN LATERAL (
    SELECT SUM(total_road_frontage) AS total_road_frontage
    FROM property.property_road_frontage rf
    WHERE rf.prop_no = p.prop_no
) rf

-- Vacancy
CROSS JOIN LATERAL (
    SELECT COUNT(*) = 0 AS is_vacant
    FROM property.building_footprints_2025 b
    WHERE ST_Intersects(p.geom, ST_Transform(b.geom, 2193))
      AND bf.overlap_area >= (SELECT value_numeric FROM property.get_rule_record('min_building_area'))
) vac

GROUP BY 
    p.prop_no,
    p.geom,
    cfg.overlay_geom,
    bf.overlap_area,
    bf.overlap_pct,
    dev.developable_geom,
    dev.developable_area,
    dev.developable_pct,
    rf.total_road_frontage,
    vac.is_vacant

WITH DATA;

$sql$, dyn_cols);

-- Execute
EXECUTE sql;

-- ---------------------------------
-- Permissions
-- ---------------------------------
ALTER TABLE property.property_grz_ldcap_viability_overlay_analysis OWNER TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_viability_overlay_analysis TO postgres;
GRANT ALL ON TABLE property.property_grz_ldcap_viability_overlay_analysis TO wdc;
GRANT SELECT ON TABLE property.property_grz_ldcap_viability_overlay_analysis TO wdc_gisprod;

-- ---------------------------------
-- Indexes
-- ---------------------------------
CREATE INDEX property_grz_ldcap_viability_overlay_analysis_fid_idx
    ON property.property_grz_ldcap_viability_overlay_analysis(fid);

CREATE INDEX property_grz_ldcap_viability_overlay_analysis_prop_no_idx
    ON property.property_grz_ldcap_viability_overlay_analysis(prop_no);

CREATE INDEX property_grz_ldcap_viability_overlay_analysis_geom_idx
    ON property.property_grz_ldcap_viability_overlay_analysis USING gist(geom);

CREATE INDEX property_grz_ldcap_overlay_constraints_geom_idx
    ON property.property_grz_ldcap_viability_overlay_analysis USING gist(overlay_geom);

CREATE INDEX property_grz_ldcap_overlay_dev_geom_idx
    ON property.property_grz_ldcap_viability_overlay_analysis USING gist(developable_geom);

-- Comment
EXECUTE format(
    $$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_viability_overlay_analysis IS 'Regenerated by Stored Procedure %s (OPTIMISED DYN)'$$,
    LOCALTIMESTAMP
);

END;
$BODY$;


ALTER PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis() TO PUBLIC;
GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis() TO postgres;
GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis() TO wdc;
GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis() TO wdc_gisprod;
-- Create table
CREATE TABLE property.property_grz_ldcap_exclusion_thresholds (
    fid INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,

    metric_name TEXT NOT NULL,

    operator TEXT NOT NULL CHECK (
        operator IN ('>', '>=', '<', '<=', '=', 'BETWEEN')
    ),

    -- Single-value threshold
    threshold NUMERIC,

    -- Range thresholds (used only for BETWEEN)
    threshold_min NUMERIC,
    threshold_max NUMERIC,

    -- Geometry column (NZTM)
    geom geometry(MultiPolygon, 2193) NOT NULL
        DEFAULT ST_GeomFromText('MULTIPOLYGON EMPTY', 2193),

    -- Data integrity rule:
    CHECK (
        -- For non-BETWEEN operators
        (operator <> 'BETWEEN'
            AND threshold IS NOT NULL
            AND threshold_min IS NULL
            AND threshold_max IS NULL
        )
        OR
        -- For BETWEEN operator
        (operator = 'BETWEEN'
            AND threshold IS NULL
            AND threshold_min IS NOT NULL
            AND threshold_max IS NOT NULL
        )
    )
);

-- Optional: ensure metric names are unique
CREATE UNIQUE INDEX ux_property_grz_ldcap_exclusion_thresholds_metric
ON property.property_grz_ldcap_exclusion_thresholds (metric_name);




ALTER TABLE property.property_grz_ldcap_exclusion_thresholds
    OWNER TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_exclusion_thresholds TO postgres;
GRANT ALL ON TABLE property.property_grz_ldcap_exclusion_thresholds TO wdc;
GRANT SELECT ON TABLE property.property_grz_ldcap_exclusion_thresholds TO wdc_gisprod;

-- Insert current threshold rules

INSERT INTO property.property_grz_ldcap_exclusion_thresholds (metric_name, operator, threshold)
VALUES
    ('lidar2020_dem_1m_slope_geq20', '>', 30),
    ('land_stability_assessment_area_a', '>', 0),
    ('land_stability_assessment_area_b', '>=', 30),
    ('flood_risk_area_a', '>=', 30),
    ('flood_risk_area_b', '>=', 30),
    ('ht_powerlines_10m_setback', '>=', 30),
    ('ht_pylons_12m_setback', '>=', 30),
    ('lidar2020_dem_depression_areas_gt_300', '>=', 30),
    ('highliquefaction', '>=', 30);




ALTER TABLE property.property_grz_ldcap_exclusion_thresholds
ADD COLUMN source_column TEXT;

UPDATE property.property_grz_ldcap_exclusion_thresholds
SET source_column = CASE metric_name
    WHEN 'lidar2020_dem_1m_slope_geq20' THEN 'prop_overlap_pct_lidar2020_dem_1m_slope_geq20'
    WHEN 'land_stability_assessment_area_a' THEN 'prop_overlap_pct_land_stability_assessment_area_a'
    WHEN 'land_stability_assessment_area_b' THEN 'prop_overlap_pct_land_stability_assessment_area_b'
    WHEN 'flood_risk_area_a' THEN 'prop_overlap_pct_flood_risk_area_a'
    WHEN 'flood_risk_area_b' THEN 'prop_overlap_pct_flood_risk_area_b'
    WHEN 'ht_powerlines_10m_setback' THEN 'prop_overlap_pct_ht_powerlines_10m_setback'
    WHEN 'ht_pylons_12m_setback' THEN 'prop_overlap_pct_ht_pylons_12m_setback'
    WHEN 'lidar2020_dem_depression_areas_gt_300' THEN 'prop_overlap_pct_lidar2020_dem_depression_areas_gt_300'
    WHEN 'highliquefaction' THEN 'prop_overlap_pct_highliquefaction'
END;

-- Table: property.property_grz_ldcap_overlay_analysis_config

-- DROP TABLE IF EXISTS property.property_grz_ldcap_overlay_analysis_config;

CREATE TABLE IF NOT EXISTS property.property_grz_ldcap_overlay_analysis_config
(
    id integer NOT NULL DEFAULT nextval('overlay_calc_config_id_seq'::regclass),
    group_name text COLLATE pg_catalog."default",
    alias text COLLATE pg_catalog."default" NOT NULL,
    schema_name text COLLATE pg_catalog."default" NOT NULL,
    table_name text COLLATE pg_catalog."default" NOT NULL,
    filter_sql text COLLATE pg_catalog."default",
    include_in_overlay boolean DEFAULT true,
    sort_order integer NOT NULL,
    geom geometry(MultiPolygon,2193) NOT NULL DEFAULT st_geomfromtext('MULTIPOLYGON EMPTY'::text, 2193),
    CONSTRAINT overlay_calc_config_pkey PRIMARY KEY (id),
    CONSTRAINT overlay_calc_config_alias_key UNIQUE (alias)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS property.property_grz_ldcap_overlay_analysis_config
    OWNER to postgres;

REVOKE ALL ON TABLE property.property_grz_ldcap_overlay_analysis_config FROM wdc_gisprod;

GRANT ALL ON TABLE property.property_grz_ldcap_overlay_analysis_config TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_overlay_analysis_config TO wdc;

GRANT SELECT ON TABLE property.property_grz_ldcap_overlay_analysis_config TO wdc_gisprod;



INSERT INTO property.overlay_calc_config (
    group_name,
    alias,
    schema_name,
    table_name,
    filter_sql,
    include_in_overlay,
    sort_order,
)
VALUES

-- -------------------------
-- Planning
-- -------------------------
('planning', 'des', 'eplan', 'designations', NULL, true, 1),
('planning', 'osz', 'eplan', 'osz_open_space_zone', NULL, true, 2),

-- -------------------------
-- Infrastructure
-- -------------------------
('infra', 'fac', 'general', 'whanganui_local_facilities', NULL, true, 3),
('infra', 'bcgt25', 'property', 'property_building_consents_dwellings_gt20250206', NULL, true, 4),
('infra', 'htpl', 'eplan', 'high_tension_powerlines_10m_setback', NULL, true, 5),
('infra', 'htpp', 'eplan', 'high_tension_pylons_12m_setback', NULL, true, 6),

-- -------------------------
-- Hazards
-- -------------------------
('hazards', 'fra', 'eplan', 'flood_risk_area_a', NULL, true, 7),
('hazards', 'frb', 'eplan', 'flood_risk_area_b', NULL, true, 8),
('hazards', 'lsa', 'eplan', 'land_stability_assessment_area_a', NULL, true, 9),
('hazards', 'lsb', 'eplan', 'land_stability_assessment_area_b', NULL, true, 10),
('hazards', 'da300', 'hazards', 'lidar2020_dem_depression_areas_greater_than_300mm_final', NULL, true, 11),
('hazards', 's20', 'lidar', 'lidar2020_dem_1m_slope_geq20', NULL, true, 12),
('hazards', 'hl', 'hazards', 'highliquefaction', NULL, true, 13);
CREATE TABLE property.property_grz_ldcap_rules (
    fid integer NOT NULL GENERATED BY DEFAULT AS IDENTITY ( INCREMENT 1 START 1 MINVALUE 1 MAXVALUE 2147483647 CACHE 1 ),
	rule_name TEXT PRIMARY KEY,
    rule_group TEXT NOT NULL,   -- e.g. 'geometry', 'density', 'access'
    value_numeric NUMERIC,
    value_text TEXT,
    value_bool BOOLEAN,
    description TEXT,
    updated_at TIMESTAMP DEFAULT now()
);


ALTER TABLE IF EXISTS property.property_grz_ldcap_rules
    OWNER to postgres;

REVOKE ALL ON TABLE property.property_grz_ldcap_rules FROM wdc_gisprod;

GRANT ALL ON TABLE property.property_grz_ldcap_rules TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_rules TO wdc;

GRANT SELECT ON TABLE property.property_grz_ldcap_rules TO wdc_gisprod;


-- Index: ux_property_grz_ldcap_rules_rule_name

-- DROP INDEX IF EXISTS property.ux_property_grz_ldcap_rules_rule_name;

CREATE UNIQUE INDEX IF NOT EXISTS ux_property_grz_ldcap_rules_rule_name
    ON property.property_grz_ldcap_rules USING btree
    (rule_name COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;


INSERT INTO property.property_grz_ldcap_rules (rule_name, rule_group, value_numeric, description)
VALUES
-- Geometry
('min_building_area', 'geometry', 60, 'Minimum building footprint area'),
('min_mic_radius', 'geometry', 7, 'Minimum radius for building platform'),

-- Density
('min_lot_size_standard', 'density', 400, 'Standard minimum lot size'),
('min_lot_size_overlay', 'density', 800, 'Overlay minimum lot size'),

-- Access
('min_frontage_general', 'access', 3.6, 'Minimum access width'),
('min_frontage_large_scale', 'access', 10, 'Frontage required for large scale'),

-- Viability
('max_building_coverage', 'viability', 0.25, 'Max building coverage threshold'),

-- Spatial heuristics
('min_frontage_quadrant', 'geometry', 15, 'Minimum frontage for quadrant viability');	



-- so we can easily view in QGIS add empty geom column
ALTER TABLE property.property_grz_ldcap_rules
    ADD COLUMN geom geometry(MultiPolygon, 2193) NOT NULL
        DEFAULT ST_GeomFromText('MULTIPOLYGON EMPTY', 2193);


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
-- FUNCTION: property.get_rule_record(text)

-- DROP FUNCTION IF EXISTS property.get_rule_record(text);

CREATE OR REPLACE FUNCTION property.get_rule_record(
	p_rule_name text)
    RETURNS TABLE(value_numeric numeric, value_text text, value_bool boolean) 
    LANGUAGE 'sql'
    COST 100
    STABLE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
    SELECT value_numeric, value_text, value_bool
    FROM property.property_grz_ldcap_rules
    WHERE rule_name = p_rule_name;
$BODY$;

ALTER FUNCTION property.get_rule_record(text)
    OWNER TO postgres;

GRANT EXECUTE ON FUNCTION property.get_rule_record(text) TO PUBLIC;

GRANT EXECUTE ON FUNCTION property.get_rule_record(text) TO postgres;

GRANT EXECUTE ON FUNCTION property.get_rule_record(text) TO wdc;

GRANT EXECUTE ON FUNCTION property.get_rule_record(text) TO wdc_gisprod;

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
            AND ST_Area(g.geom) >= property.get_rule_record('min_building_area')
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

