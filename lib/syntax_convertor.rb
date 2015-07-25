require 'plist'

module Sublime
  class SyntaxConvertor
    attr_reader :syntax

    def initialize(lang)
      @lang       = Plist.parse_xml(lang)
      @repository = @lang.fetch('repository', {})
      @patterns   = @lang.fetch('patterns', [])
      @syntax     = {}
      @contexts   = {}
      normalize_repository
      convert
    end

    def to_yaml(val = @syntax, start_block_on_newline = false, indent = 0)
      tab_size = 2
      out = ""

      if indent == 0
        out += "%YAML 1.2\n---\n"
        out += "# http://www.sublimetext.com/docs/3/syntax.html\n"
      end

      if val.is_a?(Array)
        if val.size == 0
          out += "[]\n"
        else
          out += "\n" if start_block_on_newline
          val.each do |x|
            out += " " * indent
            out += "- "
            out += to_yaml(x, false, indent + 2)
          end
        end
      elsif val.is_a?(Hash)
        out += "\n" if start_block_on_newline
        first = true
        order_keys(val.keys).each do |k|
          v = val[k]
          if !first || start_block_on_newline
            out += " " * indent
          else
            first = false
          end

          if k.is_a?(Numeric)
            out += k.to_s
          elsif needs_yaml_quoting(k)
            out += quote(k)
          else
            out += k
          end

          out += ": "
          out += to_yaml(v, true, indent + tab_size)
        end
      elsif val.is_a?(String)
        if needs_yaml_quoting(val)
          if val.include?("\n")
            fail unless start_block_on_newline
            if start_block_on_newline
              if val[-1] == "\n"
                out += "|\n"
              else
                out += "|-\n"
              end
            end
            val.split("\n").each do |l|
              out += " " * indent
              out += l
              out += "\n"
            end
          else
            out += quote(val)
            out += "\n"
          end
        else
          out += val
          out += "\n"
        end
      elsif val.is_a?(TrueClass) || val.is_a?(FalseClass)
        if val
          out += "true\n"
        else
          out += "false\n"
        end
      else
        out += "#{val}\n"
      end
      # to_yaml will leave some trailing whitespace, remove it
      cleaned_yaml = out.split("\n").map(&:rstrip).join("\n") + "\n"
      cleaned_yaml
    end

    private

    # normalize the repository values into being a list of patterns
    def normalize_repository
      @repository.each do |key, value|
        if value.key?('begin') || value.key?('match')
          @repository[key] = [value]
        else
          @repository[key] = value['patterns']
        end
      end
    end

    def create_contexts
      @contexts['main'] = make_context(@lang['patterns'])
      @repository.each do |key, value|
        fail 'Double definition of main context' if key == 'main'
        @contexts[key] = make_context(value)
      end
    end

    def convert
      syntax = {}
      create_contexts

      if @lang.key?('comment')
        comment = format_comment(@lang['comment'])
        syntax['comment'] = comment unless comment.empty?
      end

      syntax['first_line_match'] = format_regex(@lang['firstLineMatch']) if @lang.key?('firstLineMatch')
      syntax['name']             = @lang['name']           if @lang.key?('name')
      syntax['scope']            = @lang['scopeName']      if @lang.key?('scopeName')
      syntax['file_extensions']  = @lang['fileTypes']      if @lang.key?('fileTypes')
      syntax['hidden']           = @lang['hideFromUser']   if @lang.key?('hideFromUser')
      syntax['hidden']           = @lang['hidden']         if @lang.key?('hidden')
      syntax['contexts']         = @contexts

      @syntax = syntax
    end

    def handle_begin_pattern(p)
      entry = {}
      entry['match'] = format_regex(p['begin'])
      if p.key?('beginCaptures') || p.key?('captures')
        if p.key?('beginCaptures')
          captures = format_captures(p['beginCaptures'])
        else
          captures = format_captures(p['captures'])
        end
        if captures.key?('0')
          entry['scope'] = captures['0']
          captures.delete('0')
        end
        entry['captures'] = captures if captures.size > 0
      end

      end_entry = {}
      end_entry['match'] = format_regex(p['end'])
      end_entry['pop'] = true
      if p.key?('endCaptures') || p.key?('captures')
        if p.key?('endCaptures')
          captures = format_captures(p['endCaptures'])
        else
          captures = format_captures(p['captures'])
        end
        if captures.key?('0')
          end_entry['scope'] = captures['0']
          captures.delete('0')
        end
        end_entry['captures'] = captures if captures.size > 0
      end

      if end_entry['match'].include? "\\G"
        puts """WARNING:
        pop pattern contains \\G, this will not work as expected
        if it's intended to refer to the begin regex:
          #{end_entry['match']}
        """
      end

      apply_last = p.key?('applyEndPatternLast') && p['applyEndPatternLast'] == 1
      child_patterns =  p.key?('patterns') ? p["patterns"] : []
      child = make_context(child_patterns)
      apply_last ? child.push(end_entry) : child.unshift(end_entry)
      child.unshift('meta_content_scope' => p['contentName']) if p.key?('contentName')
      child.unshift('meta_scope' => p['name']) if p.key?('name')

      if p.key?('comment')
        comment = format_comment(p["comment"])
        entry['comment'] = comment if comment.size > 0
      end
      entry['push'] = child
      entry
    end

    def handle_match_pattern(p)
      entry = {}
      entry['match'] = format_regex(p['match'])
      entry['scope'] = p['name'] if p.key?('name')
      entry['captures'] = format_captures(p['captures']) if p.key?('captures')
      if p.key?('comment')
        comment = format_comment(p['comment'])
        entry['comment'] = comment if comment.size > 0
      end
      entry
    end

    def handle_include_pattern(p)
      key = p['include']
      if key[0] == '#'
        key = key[1..-1]
        fail Exception("no entry in repository for #{key}") unless @repository.key?(key)
        return { 'include' => key }
      elsif key == '$self'
        return { 'include' => 'main' }
      elsif key == '$base'
        return { 'include' => '$top_level_main' }
      elsif key[0] == '$'
        fail Exception "unknown include: #{key}"
      else
        return { 'include' => format_external_syntax(key) }
      end
    end

    def make_context(patterns)
      ctx = []
      patterns.each do |p|
        if p.key?('begin')
          entry = handle_begin_pattern(p)
        elsif p.key?('match')
          entry = handle_match_pattern(p)
        elsif p.key?('include')
          entry = handle_include_pattern(p)
        else
          fail Exception("unknown pattern type: #{p.keys}")
        end
        ctx.push(entry) if entry
      end
      ctx
    end

    def format_comment(s)
      s = s.strip.gsub("\t", "    ")
      s = s.rstrip + "\n" if s.include?("\n")
      s
    end

    def format_regex(s)
      if s.include? "\n"
        lines = s.split("\n")
        # trim common indentation off of each line
        if lines.size > 1
          common_indent = leading_whitespace(lines[1])
          lines[2..-1].each do |l|
            cur_indent = leading_whitespace(l)
            if cur_indent.start_with?(common_indent)
              next
            elsif common_indent.start_with?(cur_indent)
              common_indent = cur_indent
            else
              common_indent = ''
            end
          end
          # Generally the first line doesn't have any indentation, add some
          lines[0] = common_indent + lines[0].lstrip unless lines[0].start_with?(common_indent)
        else
          common_indent = leading_whitespace(lines[0])
        end
        s = lines.map { |l| l[common_indent.size..-1] }.join("\n").rstrip
      end
      s
    end

    def format_captures(c)
      captures = {}
      c.each do |k, v|
        unless v.key?('name')
          puts "patterns and includes are not supported within captures: #{c}"
          next
        end

        begin
          captures[k.to_i] = v['name']
        rescue
          puts 'named capture used, this is unsupported'
          captures[k] = v['name']
        end
      end
      captures
    end

    def format_external_syntax(key)
      fail 'invalid external syntax name' if '#$'.include?(key[0])
      if key.include?('#')
        syntax, rule = key.split('#')
        return "scope:#{syntax}##{rule}"
      else
        return "scope:#{key}"
      end
    end

    def leading_whitespace(s)
      s[0...(s.size - s.lstrip.size)]
    end

    #----------------------------------------------------------

    def order_keys(l)
        key_order = %w(name main match comment file_extensions first_line_match hidden match scope main).reverse
        l = l.sort
        key_order.each do |key|
          if l.include?(key)
            l.delete_at(l.index(key))
            l.insert(0, key)
          end
        end
        l
    end

    def needs_yaml_quoting(s)
      (
        s == "" ||
        "\"'%-:?@`&*!,#|>0123456789=".include?(s[0]) ||
        s.start_with?('<<') ||
        ['true', 'false', 'null'].include?(s) ||
        s.include?("# ") ||
        s.include?(': ') ||
        s.include?('[') ||
        s.include?(']') ||
        s.include?('{') ||
        s.include?('}') ||
        s.include?("\n") ||
        ":#".include?(s[-1]) ||
        s.strip != s
      )
    end

    def quote(s)
      if s.include?("\\") || s.include?('"')
        return "'" + s.gsub("'", "''") + "'"
      else
        return '"' + s.gsub("\\", "\\\\").gsub('"', '\\"') + '"'
      end
    end

  end
end