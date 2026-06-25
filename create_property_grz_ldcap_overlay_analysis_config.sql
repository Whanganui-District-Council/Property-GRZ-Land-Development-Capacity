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



INSERT INTO property.property_grz_ldcap_overlay_analysis_config (
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
