# frozen_string_literal: true

module Sidefx
  # Renders a Receipt as, well, a receipt.
  class Printer
    WIDTH = 60

    SECTIONS = [
      [:write, "DATABASE WRITES"],
      [:job, "JOBS ENQUEUED"],
      [:mail, "EMAILS"],
      [:http, "HTTP REQUESTS"],
      [:broadcast, "BROADCASTS"],
      [:cache, "CACHE CHANGES"]
    ].freeze

    def initialize(receipt)
      @r = receipt
      @out = +""
    end

    def to_s
      header
      if @r.committed.empty?
        rule
        center("NO SIDE EFFECTS")
        center("nothing outside Ruby changed")
      end
      SECTIONS.each { |kind, title| section(title, @r.committed.select { |e| e.kind == kind }) }
      section("ROLLED BACK · these did not happen", @r.rolled_back) if @r.rolled_back.any?
      callbacks
      reads
      footer
      @out
    end

    private

    def line(s = "")
      @out << s.rstrip << "\n"
    end

    def rule(char = "-")
      line(char * WIDTH)
    end

    def center(s)
      line(s.center(WIDTH))
    end

    # "INSERT orders ......................... 1 row"
    def leader(left, right, indent: 2)
      left = "#{' ' * indent}#{left} "
      right = " #{right}"
      dots = WIDTH - left.length - right.length
      dots = 3 if dots < 3
      line(left + ("." * dots) + right)
    end

    def header
      rule("=")
      center("S I D E F X")
      center("side-effect receipt")
      center(@r.title.to_s) if @r.title
      center(Time.now.strftime("%Y-%m-%d %H:%M:%S") + format(" · %.1f ms", @r.duration_ms))
    end

    def section(title, effects)
      return if effects.empty?

      rule
      line(title)
      effects.group_by { |e| [e.kind, e.label, e.detail[:via]] }.each do |(kind, label, _), group|
        leader(label + (group.size > 1 ? " ×#{group.size}" : ""), amount(kind, group))
        extra = detail(group.first)
        line("      #{extra}") if extra
        if group.any? { |e| e.detail[:inside_rollback] }
          line("      ! ran inside a transaction that rolled back")
          line("        (the database undo didn't undo this)")
        end
        loc = group.first.location
        line("      ↳ #{loc}") if loc
      end
    end

    def amount(kind, group)
      case kind
      when :write
        rows = group.sum(&:count)
        "#{rows} row#{'s' unless rows == 1}"
      when :http then group.map { |e| e.detail[:status] }.compact.uniq.join(",")
      when :mail then group.first.detail[:via].to_s
      when :job then group.first.detail[:queue].to_s
      else group.size.to_s
      end
    end

    def detail(e)
      case e.kind
      when :mail then "to #{e.detail[:to]}" if e.detail[:to].to_s != ""
      when :job then e.detail[:when] if e.detail[:when].to_s != ""
      end
    end

    def callbacks
      runs, framework_only = @r.callbacks.values.partition { |run| run.declared.any? }
      return if runs.empty?

      rule
      line("CALLBACKS RUN")
      runs.each do |run|
        leader("#{run.model} #{run.kind}", "×#{run.runs}")
        run.declared.each do |d|
          maybe = d.conditional ? " (conditional)" : ""
          line("      #{d.label}#{maybe}")
          line("        ↳ #{d.location}")
        end
      end
      return if framework_only.empty?

      n = framework_only.size
      line("  (+#{n} chain#{'s' unless n == 1} with only framework callbacks)")
    end

    def reads
      return if @r.reads.empty?

      rule
      tables = @r.reads.map(&:table).uniq
      leader("READS", "#{@r.reads.size} quer#{@r.reads.size == 1 ? 'y' : 'ies'} · #{tables.size} table#{'s' unless tables.size == 1}", indent: 0)
      @r.n_plus_ones.first(3).each do |(_, table, n)|
        loc = @r.reads.find { |x| x.table == table }&.location
        line("  ! N+1? SELECT #{table} ×#{n}#{"  #{loc}" if loc}")
      end
    end

    def footer
      rule("=")
      leader("TOTAL SIDE EFFECTS", @r.committed.size.to_s, indent: 0)
      leader("ROLLED BACK", @r.rolled_back.size.to_s, indent: 0) if @r.rolled_back.any?
      rule("=")
      center(@r.committed.empty? ? "thank you for not touching anything" : "thank you, come again")
    end
  end
end
