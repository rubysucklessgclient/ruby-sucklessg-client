#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'date'

$DEBUG=false

module SucklessG

  Domain='sucklessg.org'


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
    ExitCmd=[
        "",
        "exit the program. You can also press Ctrl+D or Ctrl+C",
        -> { exit }
    ]
    Commands = {
      help: [
        "[command]",
        "get help in general or for the specific command",
        ->(cmd=nil) { 
          if cmd.nil?
            return ["read the source code to actually know...\n\n",'command help format:',"*cmd* *arguments*\n\t[description]\n\t","\n"] + SucklessG::UI::Commands.map{|k,v| "#{k} #{v[0]}\n\t#{v[1]}\n\n" }
          else
            return 'command specific help not implemented'
          end
        }
      ],
      page: [
        "n",
        "get page of a specified number",
        ->(n) { Get::Page.new(n).to_s }
      ],
      read: [
        "uuid",
        "read the post of specified uuid\n\tright now, this always returns an error",
        ->(id) { Get::Post.new(id).to_s }
      ],
      write: [
        "[reply_to_id]",
        "write a post, optionally in response to a post ID\n\tuses $EDITOR to write the post\n\tthen uses `display` from imagemagick to show the captcha image, when you type the captcha text and hit enter the post will send.\n\tright now, responding to posts doesn't seem to work",
        ->(reply_to_id=nil) { Writer.new(reply_to_id) }

      ],
      captcha: [
        "",
        "useless function at the moment. captcha is shown when using 'write' command instead",
        ->(){
          Get::Captcha.new
        }
      ],
      quit: ExitCmd,
      exit: ExitCmd,
    }
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
        puts Commands[cmd].last.call(*args)
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
