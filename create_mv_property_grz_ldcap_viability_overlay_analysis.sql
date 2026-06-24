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
    'ST_Area(geom) >= 60 AND status IS DISTINCT FROM ''Deleted'''
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
      AND bf.overlap_area >= 60
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
