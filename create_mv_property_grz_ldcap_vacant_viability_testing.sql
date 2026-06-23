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
      AND overlap < 40

    UNION ALL

    -- 3. Undersized lots
    SELECT p.prop_no
    FROM property.property p
    WHERE ST_Area(p.geom) < CASE 
        WHEN EXISTS (
            SELECT 1 
            FROM property.property_eplan_overlays o 
            WHERE o.prop_no = p.prop_no 
              AND o.layer = 'north_west_structure_plan_overlay'
        ) THEN 800
        ELSE 400
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
	WHERE prop_no IN (8075,8104,9692,33718,80750,2059,428,676,1394)

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
WHERE mic.radius >= 7
AND (
    ST_Area(p.geom) - ST_Area(dor.geom) + (PI() * (7 ^ 2))
	) > 30





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

