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

