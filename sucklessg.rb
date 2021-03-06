#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'date'

$DEBUG=false

module SucklessG

  Domain='sucklessg.org'

  module Config

    # lazy code, but basically, use XDG_CONFIG_HOME/sucklessg first,
    # if XDG_CONFIG_HOME is not set, try ~/.config/sucklessg
    # if ~/.config/sucklessg does not work,
    # if ~/.sucklessg does not work,
    # use ./.sucklessg
    if File.exist?(ENV['XDG_CONFIG_HOME'] ? ENV['XDG_CONFIG_HOME'] : '')
      config_dir = File.join(ENV['XDG_CONFIG_HOME'],'sucklessg')
    elsif (! ENV['HOME'].nil? ) && File.exist?(File.join(ENV['HOME'],'.config'))
      config_dir = File.join(ENV['HOME'],'.config','sucklessg')
    elsif (! ENV['HOME'].nil? )
      config_dir = File.join(ENV['HOME'],'.sucklessg')
    else
      config_dir = File.join('.','.sucklessg')
    end
    RC_FILE = File.join(config_dir,'config.json')
    Options=[]
    Option=Class.new do
      attr_reader :name, :default, :description, :example
      attr_accessor :value
      def initialize(**argh)
        @name=argh[:name]
        @default=argh[:default]
        @value=argh[:default]
        @description=argh[:description]
        @example=argh[:example]
        Config::Options << self
      end
    end
    Option.new({
      name: :captcha_viewer,
      default: 'display',
      description: 'command to view captcha images with (must support SVG)',
      example: '`display`, or `firefox` would work',
    })
    Option.new({
      name: :editor,
      default: nil,
      description: 'command to use for writing posts. by default this is unset and $EDITOR is used. fallbacks are emacs, vi, and nano',
      example: '`gvim`, `nvim`, `emacs`, `kate`, `gedit` or any other plain text editor. leave this unset to use $EDITOR from the environment',
    })
    Option.new({
      name: :post_format,
      default: :default,
      description: 'formatting method for displaying posts. at the moment, there is only the default built-in formatter',
      example: ':default',
    })
    Option.new({
      name: :debug,
      default: false,
      description: 'whether or not to show debugging messages',
      example: 'true or false',
    })
  end


  module Common

    def mkuri(*arr)
      return URI("https://#{Domain}/#{arr.map(&:to_s).join(?/)}")
    end

    def get_json(uri)
      return Net::HTTP.start(uri.host,uri.port,use_ssl:true) do |http|
        req = Net::HTTP::Get.new uri
        res = http.request req
        res.each_name(){|name|debug "#{name}" ; debug res.get_fields(name)}
        return(JSON.load res.body)
      end
    end

    def format_thread_post(post)
      "%{id}\n%{wrote} wrote on %{created} %{rt}%{replies}:\n\t%{content}" % {
        id: post["id"],
        wrote: post["wrote"],
        #created: DateTime.iso8601(post["created"]).strftime('%Y-%m-%d %H%M'),
        created: post["created"],
        rt: post["reply_to"].nil? ? "" : "\nin reply to #{post["reply_to"]} ",
        replies: post.include?("replies") ? "\n(#{post["replies"]} replies)" : "",
        content: post["content"].gsub(?\n,"\n\t"),
      }
    end


    if $DEBUG
      def debug(*strs)
        $stderr.puts strs
      end
    else
      def debug(*a)
        a
      end
    end

    def warn(*strs)
      print "\e[0;33m"
      $stderr.puts strs
      print "\e[0;0m"
    end

  end


  module Get

    class Page

      include SucklessG::Common
      attr_reader :json

      def initialize(n)
        uri = mkuri('page',n)
        j = get_json(uri)
        debug "Got page #{n} json: #{j}"
        @json=j
      end

      def [](a)
        @json[a]
      end

      def posts
        ret = @json.map do |h|
          id = h['id']
          debug "Getting post with id #{id}"
          Post.new(h['id'])
        end
        return ret
      end

      def to_s
        @json.map{|post|
          format_thread_post(post)
        }.join("\n\n")
      end

    end


    class Post

      include Common
      attr_reader :json

      def initialize(id)
        uri = mkuri('post',id)
        debug "Getting post from #{uri}"
        @json=get_json(uri)
      end

      def [](a)
        @json[a]
      end

      def to_s()
        @json.map{|post|
          format_thread_post(post)
        }.join("\n\n")
      end

    end


    class Captcha

      include Common

      def initialize()
        uri = mkuri('captcha')
        temp = `mktemp --suffix .svg`.chomp
        File.open(temp,'w'){|io|
          io.write get_json(uri)['svg']
        }
        #@disp_pid = spawn("display #{temp}")
      end

    end


  end


  module Post
    class Post
      include SucklessG::Common
      def initialize(content,reply_to=nil)
        # TODO: move captcha and session/cookie handling out of this method
        uri = mkuri('captcha')
        Net::HTTP.start(uri.host,uri.port,use_ssl:true) do |http|
          req = Net::HTTP::Get.new uri
          res = http.request req
          cookie=res.get_fields('set-cookie').first
          j=JSON.load(res.body)
          temp = `mktemp --suffix .svg`.chomp
          File.open(temp,'w'){|io| io.write j['svg'] }
          disp_pid = spawn ("display #{temp}")
          puts "Captcha is being displayed, please type the captcha text and press enter.\n\n"
          print "captcha > "
          c=$stdin.gets.chomp
          p c
          Process.kill("TERM",disp_pid)
          req = Net::HTTP::Post.new(mkuri('post'), { 'Content-Type' => 'application/json', 'Cookie' => cookie })
          req_body ={content: content, captcha: c}
          unless reply_to.nil?
            req_body[:reply_to] = reply_to
          end
          req.body = req_body.to_json
          res = http.request(req)
          j = JSON.load(res.body)
          debug j
        end
      end
    end

  end

  class Writer
    class NoEditorException < Exception ; end
    def initialize(reply_to_id=nil)
      Post::Post.new(write_post(),reply_to_id)
    end
    def write_post()
      editors = [ ENV['EDITOR'], 'emacs', 'vi', 'nano' ].map{|e|`which #{e} 2>/dev/null`.chomp}
      editor = nil
      editors.each do |epath|
        if File.executable?(epath)
          editor = epath
          break
        end
      end
      raise NoEditorException if editor.nil?

      t=`mktemp`.chomp
      p=spawn("#{editor} #{t}")
      Process.wait(p)
      content=File.read(t)
      return content
    end
  end


  class UI
    include Common
    Commands = {}
    Command = Class.new do
      attr_reader :name, :arg_help, :description, :function
      attr_accessor :is_alias,:alias_of
      def initialize(**argh)
        @name=argh[:name]
        @aliases=argh[:aliases]
        @arg_help=argh[:arg_help]
        @description=argh[:description]
        @function=argh[:function]
        @is_alias=false
        Commands[@name]=self
        unless @aliases.nil?
          @aliases.each do |a|
            x=self.dup
            x.is_alias = true
            x.alias_of = @name
            Commands[a]=x
          end
        end
      end
      def call(*args)
        @function.call(*args)
      end
    end
    Command.new({
      name: :help,
      arg_help: "[command]",
      description: "get help in general or for the specific command",
      function: ->(cmd=nil) {
          if cmd.nil?
            return [
              "read the source code to actually know...\n\n",
              'command help format:',
              "*cmd* *arguments*\n\t[description]\n\t","\n"
            ]+SucklessG::UI::Commands.map{|name,command|
              if command.is_alias
                "#{name} is an alias of #{command.alias_of}"
              else
                "#{name} #{command.arg_help}\n\t#{command.description.gsub(?\n,"\n\t")}\n\n"
              end
            }
          else
            return 'command-specific help not implemented'
          end
        }
    })
    Command.new({
      name: :config,
      arg_help: "[key] [value]",
      description: "without arguments, list configuration options and their values\nwith key and no value, show configuration option and it's current value.\nwith key and value, set the specified option to the specified value.",
      function: ->(key=nil, value=nil) {
          out = []
          if key.nil? && value.nil?
            Config::Options.each do |option|
              out << "#{option.name}=#{option.value}"
            end
          elsif value.nil?
            value = Config::Options.select { |option| option.name == key.to_sym }.first.value
            out << "#{key}=#{value}"
          else
            Config::Options.select{|option| option.name == key.to_sym}.first.value=value
            out << "Option '#{key}' set to '#{value}'"
          end
          return out
        }
    })
    Command.new({
      name: :page,
      arg_help: "n",
      description: "get page of a specified number",
      function: ->(n) { Get::Page.new(n).to_s }
    })
    Command.new({
      name: :read,
      arg_help: "uuid",
      description: "read the post of specified uuid\nright now, this always returns an error",
      function: ->(id) { Get::Post.new(id).to_s }
    })
    Command.new({
      name: :write,
      arg_help: "[reply_to_id]",
      description: "write a post, optionally in response to a post ID\nuses $EDITOR to write the post\nthen uses `display` from imagemagick to show the captcha image, when you type the captcha text and hit enter the post will send.\nright now, responding to posts doesn't seem to work",
      function: ->(reply_to_id=nil) { Writer.new(reply_to_id) }
    })
    Command.new({
      name: :captcha,
      description: "useless function at the moment. captcha is shown when using 'write' command instead",
      function: ->(){
          Get::Captcha.new
        }
    })
    Command.new({
      name: :quit,
      aliases: [:exit],
      description: "exit the program. You can also press Ctrl+D or Ctrl+C",
      function: -> { exit }
    })

    WelcomeText = "SucklessG in ruby...\nType 'help' for a list of commands\n\n"
    BadCommand = "Command %s does not exist or was typed incorrectly."
    InputLine = '> '

    def initialize(running=true)
      check_environment()
      puts WelcomeText
      @running = running
      while @running
        print InputLine
        input = $stdin.gets
        if input.nil?
          exit
        else
          input = input.chomp.split(' ')
          self.run(*input)
        end
      end
    end

    def check_environment()
      executables = {
        ENV['EDITOR'] => "$EDITOR is not set. Writing a post requires a text editor. The script will try emacs, vi and nano, otherwise raise an error. It's recommended to set the EDITOR environment variable.",
        'display' => "ImageMagick `display` command is not available. To write a post imagemagick's display is required to show the captcha. At the moment, this is the only way the script can display the captcha. Writing a post will be impossible without imagemagick installed",
        'mktemp' => "The mktemp program is not available. Writing a post will be broken without this program. It's possible to refactor this script to work without mktemp but that is currently not the case"
      }
      executables.each do |program,warning|
        unless File.executable?(`which #{program} 2>/dev/null`.chomp)
          warn "#{warning}\n\n"
        end
      end
    end

    def run(*args)
      cmd = args.shift.to_sym
      if Commands.include?(cmd)
        puts Commands[cmd].call(*args)
      else
        warn (BadCommand % [cmd,*args])
      end
    end
  end

end

if ARGV.size > 0
  SucklessG::UI.new(false).run(*ARGV)
else
  SucklessG::UI.new
end
