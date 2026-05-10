CREATE TABLE `syseng_decoupling_prod.netsuite_fin_transactions_pdf_status` (
  pdf_generation_status BOOLEAN OPTIONS (description = "Indicates if the PDF generation was successful (TRUE/FALSE)"),
  created_by STRING OPTIONS (description = "User or system that created the record"),
  status STRING OPTIONS (description = "Status description (e.g., 'Completed', 'Failed')"),
  datetimestamp TIMESTAMP OPTIONS (description = "Timestamp when the record was created or updated"),
  id STRING OPTIONS (description = "Unique identifier for the record")
)
OPTIONS (
  description = "Table to track the PDF generation status for documents."
)