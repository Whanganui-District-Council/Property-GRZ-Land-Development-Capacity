-- PROCEDURE: property.create_mv_property_grz_ldcap_viability_overlay_analysis()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap_viability_overlay_analysis();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis()
LANGUAGE 'sql'
AS $BODY$

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

    -- Base
    ST_Area(p.geom) AS prop_area,

    -- Building footprints (excluded from overlay geom)
    bf.overlap_area AS prop_overlap_area_building_footprints_2025_geq60,
    bf.overlap_pct  AS prop_overlap_pct_building_footprints_2025_geq60,

    -- Planning
	des.overlap_area AS prop_overlap_area_designations,
	des.overlap_pct  AS prop_overlap_pct_designations,
	
	osz.overlap_area AS prop_overlap_area_osz_open_space_zone,
	osz.overlap_pct  AS prop_overlap_pct_osz_open_space_zone,
	
	-- Infrastructure
	fac.overlap_area AS prop_overlap_area_whanganui_local_facilities,
	fac.overlap_pct  AS prop_overlap_pct_whanganui_local_facilities,
	
	bcgt25.overlap_area AS prop_overlap_area_property_bc_dwellings_gt20250206,
	bcgt25.overlap_pct  AS prop_overlap_pct_property_bc_dwellings_gt20250206,
	
	htpl.overlap_area AS prop_overlap_area_ht_powerlines_10m_setback,
	htpl.overlap_pct  AS prop_overlap_pct_ht_powerlines_10m_setback,
	
	htpp.overlap_area AS prop_overlap_area_ht_pylons_12m_setback,
	htpp.overlap_pct  AS prop_overlap_pct_ht_pylons_12m_setback,
	
	-- Hazards
	fra.overlap_area AS prop_overlap_area_flood_risk_area_a,
	fra.overlap_pct  AS prop_overlap_pct_flood_risk_area_a,
	
	frb.overlap_area AS prop_overlap_area_flood_risk_area_b,
	frb.overlap_pct  AS prop_overlap_pct_flood_risk_area_b,
	
	lsa.overlap_area AS prop_overlap_area_land_stability_assessment_area_a,
	lsa.overlap_pct  AS prop_overlap_pct_land_stability_assessment_area_a,
	
	lsb.overlap_area AS prop_overlap_area_land_stability_assessment_area_b,
	lsb.overlap_pct  AS prop_overlap_pct_land_stability_assessment_area_b,
	
	da300.overlap_area AS prop_overlap_area_lidar2020_dem_depression_gt300,
	da300.overlap_pct  AS prop_overlap_pct_lidar2020_dem_depression_gt300,
	
	s20.overlap_area AS prop_overlap_area_lidar2020_dem_slope_geq20,
	s20.overlap_pct  AS prop_overlap_pct_lidar2020_dem_slope_geq20,
	
	hl.overlap_area AS prop_overlap_area_highliquefaction,
	hl.overlap_pct  AS prop_overlap_pct_highliquefaction,

    -- Property attributes
    rf.total_road_frontage,
    vac.is_vacant,

    -- ✅ Combined constraint geometry
    ov.overlay_geom,

    -- ✅ Overlay metrics
    ST_Area(ov.overlay_geom) AS overlay_area_total,
    ST_Area(ov.overlay_geom) / ST_Area(p.geom) * 100 AS overlay_pct_total,

    -- ✅ Developable land (optimised: computed once)
    dev.developable_geom,
    dev.developable_area,
    dev.developable_pct,

    -- Base geometry
    p.geom

FROM pgrz p

-- ---------------------------------
-- Overlay calculations
-- ---------------------------------
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'eplan','designations') des
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'eplan','osz_open_space_zone') osz
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'general','whanganui_local_facilities') fac
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'property','property_building_consents_dwellings_gt20250206') bcgt25
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'eplan','flood_risk_area_a') fra
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'eplan','flood_risk_area_b') frb
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'eplan','high_tension_powerlines_10m_setback') htpl
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'eplan','high_tension_pylons_12m_setback') htpp
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'eplan','land_stability_assessment_area_a') lsa
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'eplan','land_stability_assessment_area_b') lsb
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'hazards','lidar2020_dem_depression_areas_greater_than_300mm_final') da300
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'lidar','lidar2020_dem_1m_slope_geq20') s20
CROSS JOIN LATERAL general.calc_overlap_stats_record(p.geom,'hazards','highliquefaction') hl

-- ✅ Combined overlay geometry
CROSS JOIN LATERAL (
    SELECT ST_Multi(
        ST_UnaryUnion(
            ST_Collect(ARRAY[
                des.overlap_geom,
                osz.overlap_geom,
                fac.overlap_geom,
                bcgt25.overlap_geom,
                fra.overlap_geom,
                frb.overlap_geom,
                htpl.overlap_geom,
                htpp.overlap_geom,
                lsa.overlap_geom,
                lsb.overlap_geom,
                da300.overlap_geom,
                s20.overlap_geom,
                hl.overlap_geom
            ])
        )
    ) AS overlay_geom
) ov

-- ✅ Developable land (single computation reused)
CROSS JOIN LATERAL (
    SELECT
        g AS developable_geom,
        ST_Area(g) AS developable_area,
        ST_Area(g) / ST_Area(p.geom) * 100 AS developable_pct
    FROM (
        SELECT ST_Multi(
            ST_Difference(p.geom, ov.overlay_geom)
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
    'ST_Area(geom) >= 60 AND status IS DISTINCT FROM ''Deleted'''
) bf

-- ---------------------------------
-- Road frontage
-- ---------------------------------
CROSS JOIN LATERAL (
    SELECT SUM(total_road_frontage) AS total_road_frontage
    FROM property.property_road_frontage rf
    WHERE rf.prop_no = p.prop_no
) rf

-- ---------------------------------
-- Vacancy
-- ---------------------------------
CROSS JOIN LATERAL (
    SELECT COUNT(*) = 0 AS is_vacant
    FROM property.building_footprints_2025 b
    WHERE ST_Intersects(p.geom, ST_Transform(b.geom, 2193))
	AND bf.overlap_area >= 60
) AS vac


WITH DATA;

ALTER TABLE property.property_grz_ldcap_viability_overlay_analysis
    OWNER TO postgres;

GRANT ALL ON TABLE property.property_grz_ldcap_viability_overlay_analysis TO postgres;
GRANT ALL ON TABLE property.property_grz_ldcap_viability_overlay_analysis TO wdc;
GRANT SELECT ON TABLE property.property_grz_ldcap_viability_overlay_analysis TO wdc_gisprod;

-- ---------------------------------
-- Indexes
-- ---------------------------------

CREATE INDEX property_grz_ldcap_viability_overlay_analysis_fid_idx
    ON property.property_grz_ldcap_viability_overlay_analysis USING btree
    (fid)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_viability_overlay_analysis_prop_no_idx
    ON property.property_grz_ldcap_viability_overlay_analysis USING btree
    (prop_no)
    TABLESPACE pg_default;
CREATE INDEX property_grz_ldcap_viability_overlay_analysis_geom_idx
    ON property.property_grz_ldcap_viability_overlay_analysis USING gist
    (geom)
    TABLESPACE pg_default;
CREATE INDEX property_grz_overlay_constraints_geom_idx
ON property.property_grz_ldcap_viability_overlay_analysis
USING gist (overlay_geom);

CREATE INDEX property_grz_overlay_dev_geom_idx
ON property.property_grz_ldcap_viability_overlay_analysis
USING gist (developable_geom);

DO
$do$
BEGIN
EXECUTE format($$COMMENT ON MATERIALIZED VIEW property.property_grz_ldcap_viability_overlay_analysis is 'Regenerated by Stored Procedure %s'$$, LOCALTIMESTAMP);
END
$do$
$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap_viability_overlay_analysis() TO wdc_gisprod;

