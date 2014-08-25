require "minitest/find_minimal_combination"
require "minitest/server"
require "shellwords"

class Minitest::Bisect
  VERSION = "1.0.0"

  attr_accessor :tainted, :failures, :culprits, :mode, :seen_bad
  alias :tainted? :tainted

  def self.run files
    new.run files
  end

  def initialize
    self.mode = :files
    self.culprits = []
    self.tainted = false
    self.failures = Hash.new { |h,k| h[k] = Hash.new { |h2,k2| h2[k2] = [] } }
  end

  def run files
    Minitest::Server.run self

    bisect_methods bisect_files files
  ensure
    Minitest::Server.stop
  end

  def bisect_files files
    files, flags = files.partition { |arg| File.file? arg }
    rb_flags, mt_flags = flags.partition { |arg| arg =~ /^-I/ }
    mt_flags += ["-s", $$]

    shh = " &> /dev/null"

    puts "reproducing..."
    system build_files_cmd(nil, files, nil, rb_flags, mt_flags) + shh
    abort "Reproduction run passed? Aborting." unless tainted?
    puts "reproduced"

    count = 0

    found = files.find_minimal_combination do |test|
      count += 1

      puts "# of culprits: #{test.size}"

      system build_files_cmd(nil, test, nil, rb_flags, mt_flags) + shh

      self.tainted?
    end

    puts
    puts "Final found in #{count} steps:"
    puts
    cmd = build_files_cmd nil, found, nil, rb_flags, mt_flags
    puts cmd
    cmd
  end

  def bisect_methods cmd
    self.mode = :methods
    self.seen_bad = false

    puts "reproducing..."
    repro cmd
    abort "Reproduction run passed? Aborting." unless tainted?
    puts "reproduced"

    # from: {"example/helper.rb"=>{"TestBad4"=>["test_bad4_4"]}}
    #   to: "TestBad4#test_bad4_4"
    bad = failures.values.first.to_a.join "#"

    count = 0

    found = culprits.find_minimal_combination do |test|
      count += 1

      puts "# of culprits: #{test.size}"

      repro cmd, test, bad

      self.tainted?
    end

    puts
    puts "Final found in #{count} steps:"
    puts
    cmd = build_cmd cmd, found, bad
    puts cmd
    puts
    system cmd
  end

  def build_files_cmd cmd, culprits, bad, rb, mt
    return false if bad and culprits.empty?

    self.tainted = false
    failures.clear

    tests = (culprits + [bad]).flatten.compact.map {|f| %(require "./#{f}")}
    tests = tests.join " ; "

    %(ruby #{rb.shelljoin} -e '#{tests}' -- #{mt.shelljoin})
  end

  def build_cmd cmd, culprits, bad
    return false if bad and culprits.empty?

    re = Regexp.union(culprits + [bad]).to_s.gsub(/-mix/, "") if bad
    cmd += " -n '/^#{re}$/'" if bad # += because we need a copy

    cmd
  end

  def repro cmd, culprits = [], bad = nil
    self.tainted = false
    failures.clear

    cmd = build_cmd cmd, culprits, bad
    shh = " &> /dev/null"
    system "#{cmd} #{shh}"
  end

  def result file, klass, method, fails, assertions, time
    case mode
    when :methods then
      if fails.empty? then
        culprits << "#{klass}##{method}" unless seen_bad # UGH
      else
        self.seen_bad = true
      end
    end

    unless fails.empty?
      self.tainted = true
      self.failures[file][klass] << method
    end
  end
end
