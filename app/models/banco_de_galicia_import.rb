class BancoDeGaliciaImport < Import
  after_create :set_mappings

  # Override to preprocess the Banco de Galicia CSV format
  def csv_rows
    @csv_rows ||= begin
      # Skip first 5 metadata rows from raw file
      # Banco de Galicia files have:
      # Row 1: Bank name
      # Row 2: Account number
      # Row 3: Current date
      # Row 4: Current time
      # Row 5: Query interval
      # Row 6: Column headers
      # Row 7+: Transaction data
      lines = raw_file_str.to_s.lines
      csv_content = lines.drop(5).join

      # Parse with semicolon separator
      self.class.parse_csv_str(csv_content, col_sep: ";")
    end
  end

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.map do |row|
      # Combine Débito and Crédito columns into signed amount
      # In Maybe: positive = outflow, negative = inflow
      # In Banco de Galicia CSV: Débito = negative values, Crédito = positive values
      debito = row["Débito"]
      credito = row["Crédito"]

      # Calculate amount by flipping both signs:
      # - Débito (negative in CSV) → positive in DB (outflow)
      # - Crédito (positive in CSV) → negative in DB (inflow)
      amount = if credito.present? && credito.to_s != "0,00"
        "-#{sanitize_number(credito)}" # Flip to negative (inflow)
      elsif debito.present? && debito.to_s != "0,00"
        # Débito is already negative in CSV, sanitize_number returns negative,
        # so multiply by -1 to make it positive (outflow)
        value = sanitize_number(debito)
        value.start_with?('-') ? value[1..-1] : "-#{value}"
      else
        "0"
      end

      # Clean multi-line descriptions by collapsing to single line
      description = row["Movimiento"].to_s.gsub(/\s+/, " ").strip

      {
        account: row[account_col_label].to_s,
        date: row[date_col_label].to_s,
        amount: amount,
        currency: (row[currency_col_label] || default_currency).to_s,
        name: description.presence || default_row_name,
        category: row[category_col_label].to_s,
        tags: row[tags_col_label].to_s,
        notes: row[notes_col_label].to_s
      }
    end

    rows.insert_all!(mapped_rows) if mapped_rows.any?
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      rows.each do |row|
        account = if self.account
          self.account
        else
          mappings.accounts.mappable_for(row.account)
        end

        category = mappings.categories.mappable_for(row.category)
        tags = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        entry = account.entries.build \
          date: row.date_iso,
          amount: row.signed_amount,
          name: row.name,
          currency: row.currency,
          notes: row.notes,
          entryable: Transaction.new(category: category, tags: tags),
          import: self

        entry.save!
      end
    end
  end

  def mapping_steps
    base = [ Import::CategoryMapping, Import::TagMapping ]
    base << Import::AccountMapping if account.nil?
    base
  end

  def required_column_keys
    %i[date]
  end

  def column_keys
    # Only return the columns we actually use from the Banco de Galicia format
    base = %i[date name]
    base.unshift(:account) if account.nil?
    base
  end

  def csv_template
    template = <<-CSV
      Fecha;Movimiento;Débito;Crédito;Saldo Parcial;Comentarios
      06/10/2025;COMPRA DEBITO MERPAGO*ACACIA 4425XXXXXXXXXX58 A738;13.900,00;0,00;20440,28;
      03/10/2025;CREDITO TRANSFERENCIA CALABRESE Agustin Nicolas 20247525751;0,00;287.756,65;315840,28;
    CSV

    CSV.parse(template, headers: true, col_sep: ";")
  end

  private
    def set_mappings
      self.signage_convention = "inflows_negative"
      self.col_sep = ";"
      self.number_format = "1.234,56" # European format used in Argentina
      self.date_col_label = "Fecha"
      self.date_format = "%d/%m/%Y"
      self.name_col_label = "Movimiento"
      self.amount_col_label = "amount" # We compute this ourselves from Débito/Crédito
      self.currency_col_label = nil # Not in the CSV, will use family default
      self.account_col_label = "account" if account.nil?
      self.category_col_label = nil
      self.tags_col_label = nil
      self.notes_col_label = "Comentarios"

      save!
    end
end
