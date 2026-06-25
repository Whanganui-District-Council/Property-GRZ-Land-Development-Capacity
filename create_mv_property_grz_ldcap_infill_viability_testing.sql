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

