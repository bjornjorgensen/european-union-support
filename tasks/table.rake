EXTRA_XPATHS_TO_LIST = {
  # A single `currency` label stands for 2-3 elements.
  '/OBJECT_CONTRACT/VAL_TOTAL/@CURRENCY' => [
    '/OBJECT_CONTRACT/VAL_RANGE_TOTAL/@CURRENCY',
  ],
  '/AWARD_CONTRACT/AWARDED_CONTRACT/VALUES/VAL_ESTIMATED_TOTAL/@CURRENCY' => [
    '/AWARD_CONTRACT/AWARDED_CONTRACT/VALUES/VAL_TOTAL/@CURRENCY',
    '/AWARD_CONTRACT/AWARDED_CONTRACT/VALUES/VAL_RANGE_TOTAL/@CURRENCY',
  ],
}
EXTRA_XPATHS_TO_SKIP = EXTRA_XPATHS_TO_LIST.values.flatten
KNOWN_SKIPPED_XPATHS = %w(/@LG /@CATEGORY)

desc 'Build a table with guidance'
task :table do
  def swap(labels, label_1, label_2, reverse: false)
    if reverse
      meth = :rindex
    else
      meth = :index
    end
    index_1 = labels.send(meth, label_1)
    index_2 = labels.send(meth, label_2)
    if index_1 && index_2
      labels[index_1] = label_2
      labels[index_2] = label_1
    end
  end

  def help_labels(labels, number: nil)
    index = labels.index{ |key| !help_text?(key, number: number) } || 1
    help_labels = labels[0...index]
    labels.replace(labels[index..-1])
    help_labels
  end

  def report(rows, message)
    if rows.any?
      $stderr.puts message
      $stderr.puts rows
      $stderr.puts
    end
  end

  ignore_csv = CSV.read('output/mapping/ignore.csv', headers: true)
  enumerations_csv = CSV.read('output/mapping/enumerations.csv', headers: true)
  additional_csv = CSV.read('output/mapping/additional.csv', headers: true)

  # Some forms have elements before Section 1.
  has_header = %w(01 04 07 08 12 13 15 21 22 23)

  files('output/mapping/{}*.csv').each do |filename|
    basename = File.basename(filename, '.csv').sub('_2014', '')

    if basename != 'MOVE'
      number = basename.match(/\A(F\d\d)/)[1]
      labels = label_keys(pdftotext(Dir["source/TED_forms_templates_R2.0.9/#{number}_*.pdf"][0]))
    else
      number = ENV.fetch('FORM')
      labels = CSV.read("output/labels/EN_#{ENV['FORM']}.csv").flatten
    end

    # Skip "Supplement to the Official Journal of the European Union" (HD_ojs_) and "Info and online forms" (HD_info_forms).
    labels = labels[2..-1]

    skipper = ->(row) do
      row['label-key'].nil? || EXTRA_XPATHS_TO_SKIP.include?(row['xpath'])
    end

    ### Setup

    seen = {
      enumerations: Set.new,
      filename => Set.new,
    }

    ignore = ignore_csv.select{ |row| row['numbers'][number] }
    enumerations = enumerations_csv.select{ |row| row['numbers'][number] }
    additional = additional_csv.select{ |row| row['numbers'][number] }
    data = CSV.read(filename, headers: true)

    data_skipped = data.take_while(&skipper).reject{ |row| KNOWN_SKIPPED_XPATHS.include?(row['xpath']) }
    data = data.drop_while(&skipper)

    # Swap the order of labels.
    if basename != 'MOVE'
      swap(labels, 'maintype_natagency', 'maintype_localagency')
      swap(labels, 'maintype_localauth', 'maintype_publicbody')
      swap(labels, 'maintype_localauth', 'maintype_localagency')
      swap(labels, 'mainactiv_health', 'other_activity')
      swap(labels, 'mainactiv_postal', 'other_activity', reverse: true)
    end

    ### Build

    builder = TableBuilder.new(ENV['LANGUAGE'] || 'EN')

    # Shift `notice_pin`, `notice_contract`, `notice_contract_award`, etc.
    builder.heading(number, labels.shift)

    builder.add(File.read(File.join('output', 'content', "#{basename}.md")) + "\n")

    if %w(03 06 25).include?(number)
      # Skip "Results of the procurement procedure" (notice_contract_award_sub).
      labels.shift
    end
    if !%w(08 12 13 15).include?(number)
      # Skip "Directive 2014/24/EU" (directive_201424).
      labels.shift
    end
    if basename == 'MOVE'
      # Skip notice_pubservice_pin and H_note_50000km (T01) or notice_pubservice_award_expl and H_note_voluntary_if (T02).
      labels.shift
      labels.shift
    end

    if has_header.include?(number)
      builder.table
    end

    while labels.any?
      key = labels.shift

      if key[/\A(annex_d\d|section_\d)\z/]
        if has_header.include?(number) || $1 != 'section_1'
          builder.end_table
        end
        builder.subheading(key)
        builder.table

      elsif key == '_or'
        builder.row(key)

      elsif ignore.any? && ignore[0]['label-key'] == key
        row = ignore.shift
        if !%w(icar_noticeref icar_H_year_number).include?(key)
          builder.row(key, help_labels: help_labels(labels, number: number), index: row['index'])
        end

      elsif enumerations.any? && enumerations[0]['label-key'] == key
        row = enumerations.shift
        builder.row(key, help_labels: help_labels(labels, number: number), xpath: row['xpath'], value: row['value'], guidance: row['guidance'])

        seen[:enumerations] << key

      # Fields appear in a different order in the form and XSD.
      elsif i = data[0..5].index{ |row| row['label-key'] == key }
        row = data.delete_at(i)
        builder.row(key, help_labels: help_labels(labels, number: number), xpath: row['xpath'], index: row['index'], guidance: row['guidance'])

        seen[filename] << key

        data.each do |row|
          if skipper.call(row)
            if row['label-key']
              if !EXTRA_XPATHS_TO_SKIP.include?(row['xpath'])
                data_skipped << row
              end
            else
              builder.row(nil, xpath: row['xpath'], index: row['index'], guidance: row['guidance'])
            end
          else
            break
          end
        end
        data = data.drop_while(&skipper)

      elsif additional.any? && additional[0]['label-key'] == key
        row = additional.shift
        builder.row(key, help_labels: help_labels(labels, number: number), guidance: row['guidance'])

      elsif seen[:enumerations].include?(key) || seen[filename].include?(key)
        builder.row(key, help_labels: help_labels(labels, number: number), reference: true)

      else
        # Print debug information to help diagnose the issue.
        $stderr.puts "\noutput:"
        $stderr.puts builder
        $stderr.puts "\nunprocessed rows:"
        $stderr.puts data.map(&:to_h)
        $stderr.puts "\nunprocessed labels:"
        $stderr.puts labels.inspect
        $stderr.puts data.index{ |row| row['label-key'] == key }
        $stderr.puts "ignore: #{ignore.any? && ignore[0]['label-key']}"
        $stderr.puts "enumerations: #{enumerations.any? && enumerations[0]['label-key']}"
        $stderr.puts "additional: #{additional.any? && additional[0]['label-key']}"
        raise "unexpected key '#{key}'"
      end
    end

    builder.end_table

    puts builder

    report(ignore, 'ignore.csv')
    report(enumerations, 'enumerations.csv')
    report(additional, 'additional.csv')
    report(data, basename)
    report(data_skipped, 'skipped')
  end
end
