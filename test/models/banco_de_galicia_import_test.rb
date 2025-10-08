require "test_helper"

class BancoDeGaliciaImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @import = @family.imports.create!(
      type: "BancoDeGaliciaImport",
      account: @account
    )
  end

  test "preprocesses Banco de Galicia CSV format" do
    # Sample Banco de Galicia export with metadata rows and transaction data
    csv_data = <<~CSV.strip
      ﻿Banco Galicia - Caja Ahorro Pesos;;;;;
      Nro. de Cuenta: ...9002364;;;;;
      Fecha Actual: 6/10/2025;;;;;
      Hora Actual: 17:59;;;;;
      Intervalo de Consulta: del 01/09/2025 al 07/10/2025;;;;;
      Fecha;Movimiento;Débito;Crédito;Saldo Parcial;Comentarios
      06/10/2025;"COMPRA DEBITO
       MERPAGO*ACACIA
       4425XXXXXXXXXX58
       A738";-13.900,00;0,00;20440,28;
      03/10/2025;"CREDITO TRANSFERENCIA
       CALABRESE Agustin Nicolas
       20247525751";0,00;287.756,65;315840,28;
      02/10/2025;"TRANSFERENCIA A TERCEROS
       CU  27170837172
       2850472240023337353014
       BMBS
       4425XXXXXXXXXX58
       VARIOS";-25.000,00;0,00;28083,63;
      01/10/2025;"PAGO DE SERVICIOS
       REC CLARO
       115134686900
       4425XXXXXXXXXX58
       A001";-6.000,00;0,00;21583,63;
    CSV

    @import.update!(raw_file_str: csv_data)
    @import.generate_rows_from_csv
    @import.reload

    assert_equal 4, @import.rows.count

    # Check debit row (outflow, positive in Maybe)
    debit_row = @import.rows.find { |r| r.name.include?("COMPRA DEBITO") }
    assert_equal "06/10/2025", debit_row.date
    assert_includes debit_row.name, "MERPAGO*ACACIA"
    assert_equal "13900.00", debit_row.amount # Débito (outflow) is positive in Maybe
    assert_equal "USD", debit_row.currency # Default family currency

    # Check credit row (inflow, negative in Maybe)
    credit_row = @import.rows.find { |r| r.name.include?("CREDITO TRANSFERENCIA") }
    assert_equal "03/10/2025", credit_row.date
    assert_includes credit_row.name, "CALABRESE"
    assert_equal "-287756.65", credit_row.amount # Crédito (inflow) is negative in Maybe
  end

  test "imports transactions to specified account" do
    csv_data = <<~CSV.strip
      ﻿Banco Galicia - Caja Ahorro Pesos;;;;;
      Nro. de Cuenta: ...9002364;;;;;
      Fecha Actual: 6/10/2025;;;;;
      Hora Actual: 17:59;;;;;
      Intervalo de Consulta: del 01/09/2025 al 07/10/2025;;;;;
      Fecha;Movimiento;Débito;Crédito;Saldo Parcial;Comentarios
      06/10/2025;COMPRA DEBITO MERPAGO*ACACIA;-13.900,00;0,00;20440,28;
      03/10/2025;CREDITO TRANSFERENCIA CALABRESE;0,00;287.756,65;315840,28;
    CSV

    @import.update!(raw_file_str: csv_data)
    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.reload

    assert_difference -> { Entry.count } => 2,
                      -> { Transaction.count } => 2 do
      @import.publish
    end

    assert_equal "complete", @import.status

    # All transactions should belong to the specified account
    entries = @import.entries.order(:date)
    assert_equal @account, entries.first.account
    assert_equal @account, entries.second.account

    # Check amounts are correctly signed (in Maybe: positive = outflow, negative = inflow)
    assert_equal -287756.65, entries.first.amount # Credit (inflow, negative in Maybe)
    assert_equal 13900.00, entries.second.amount # Debit (outflow, positive in Maybe)
  end

  test "handles European number format correctly" do
    csv_data = <<~CSV.strip
      ﻿Banco Galicia - Caja Ahorro Pesos;;;;;
      Nro. de Cuenta: ...9002364;;;;;
      Fecha Actual: 6/10/2025;;;;;
      Hora Actual: 17:59;;;;;
      Intervalo de Consulta: del 01/09/2025 al 07/10/2025;;;;;
      Fecha;Movimiento;Débito;Crédito;Saldo Parcial;Comentarios
      22/09/2025;TRANSFERENCIA;-1.465.950,00;0,00;6885568,69;
      22/09/2025;COMPRA;-9.000,00;0,00;6614765,69;
    CSV

    @import.update!(raw_file_str: csv_data)
    @import.generate_rows_from_csv
    @import.reload

    # Should correctly parse "1.465.950,00" as 1465950.00 (debits are positive outflows)
    large_amount_row = @import.rows.find { |r| r.amount.to_f > 1000000 }
    small_amount_row = @import.rows.find { |r| r.amount.to_f < 10000 }

    assert_equal "1465950.00", large_amount_row.amount
    assert_equal "9000.00", small_amount_row.amount
  end

  test "sets correct default mappings on creation" do
    assert_equal ";", @import.col_sep
    assert_equal "1.234,56", @import.number_format
    assert_equal "%d/%m/%Y", @import.date_format
    assert_equal "Fecha", @import.date_col_label
    assert_equal "Movimiento", @import.name_col_label
    assert_equal "inflows_negative", @import.signage_convention
  end
end
