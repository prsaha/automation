-- Find billing_account_id values in accounts that have a matching
-- custentity_ft_account_id_sf in netsuite2_sandbox.customer.
-- Use this to confirm which FIVETRAN accounts will survive the
-- billing_extract LEFT JOIN in stripe_null_netsuite_customer_id_mapping_both.sql.

select
  a.billing_account_id,
  a.stripe_customer_id,
  safe_cast(ns.id as string) as netsuite_customer_id,
  ns.companyname             as netsuite_customer_name
from `dulcet-yew-246109`.`staging_billing_public`.`accounts` a
inner join `private-internal`.`netsuite2_sandbox`.`customer` ns
  on a.billing_account_id = ns.custentity_ft_account_id_sf
  and not ns._fivetran_deleted
where not a._fivetran_deleted
order by a.billing_account_id
