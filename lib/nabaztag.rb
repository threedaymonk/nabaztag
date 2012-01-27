# This file is in UTF-8

require 'cgi'
require 'open-uri'
require 'iconv'

#
# Nabaztag allows control of the text-to-speech, ear control, and choreography features of 
# Nabaztag devices.
#
# To use this library, you need to know the MAC of the device (written on the base) and its 
# API token. The token must be obtained from http://www.nabaztag.com/vl/FR/api_prefs.jsp .
#
# The API allows different commands to be dispatched simultaneously; in order to achieve this,
# this library queues commands until they are sent.
#
# E.g.
#   nabaztag = Nabaztag.new(mac, token)
#   nabaztag.say('bonjour')   # Nothing sent yet
#   nabaztag.move_ears(4, 4)  # Still not sent
#   nabaztag.send             # Messages sent
#
# This also means that if two conflicting commands are issued without an intervening send, 
# only the latter will be carried out.
#
# However, beware! The API doesn't seem to respond well if multiple commands are sent in
# a short period of time: it can become confused and send erroneous commands to the device.
#
# In addition, the choreography command does not seem to play well with other commands: if
# text-to-speech and choreography are sent in one request, only the speech will get through
# to the rabbit.
#
# With version 2 of the API, it is now possible to specify a voice for the message. The 
# default is determined by the rabbit's language (claire22s for French; heather22k for 
# English). The voice's language overrides that of the rabbit: i.e. a French rabbit will 
# speak in English when told to use an English voice.
#
# The known voices are grouped by language in the Nabaztag::VOICES constant, but no attempt 
# is made to validate against this list, as Violet may introduce additional voices in future.
#
class Nabaztag
  
  class ServiceError < RuntimeError ; end
  
  SERVICE_ENCODING = 'iso-8859-1'
  API_URI = 'http://www.nabaztag.com/vl/FR/api.jsp?'
  
  #
  # The messages that indicate successful reception of various commands. Francophone rabbits reply in French; 
  # anglophone ones reply in English
  #
  SUCCESS_RESPONSES = {
    :say          => /Votre texte a bien été transmis|Your text was forwarded/u,
    :left_ear     => /Votre changement d'oreilles gauche a été transmis|Your left change of ears was transmitted/u,
    :right_ear    => /Votre changement d'oreilles droit a été transmis|Your right change of ears was transmitted/u,
    :choreography => /Votre chorégraphie a bien été transmis|Your choreography was forwarded/u
  }
  EAR_POSITION_RESPONSES = {
    :left  => /(?:Position gauche|Left position) = (-?\d+)/u,
    :right => /(?:Position droite|Right position) = (-?\d+)/u
  }
  
  #
  # The available voices for English and French according to the API. Note: although the French-language 
  # documentation lists the voices with leading capitals (e.g. Graham22s), the API only seems to
  # recognise names all in lower case.
  #
  VOICES = {
    :fr => %w[julie22k claire22s],
    :en => %w[graham22s lucy22s heather22k ryan22k aaron22s laura22s]
  }
  
  class <<self
  
    #
    # Override the default system encoding: use this if your program is not using UTF-8
    #
    def system_encoding=(encoding)
      @system_encoding = encoding
    end
    
    def system_encoding
      return @system_encoding || 'utf-8'
    end
  
    def encode_text(string)
      Iconv.iconv(SERVICE_ENCODING, system_encoding, string)[0]
    end
  
    def decode_response(string)
      # Responses are only used for verification, so the encoding should match the present file.
      Iconv.iconv('utf-8', SERVICE_ENCODING, string)[0]
    end
  
  end
  
  #
  # Create a new Nabaztag instance to communicate with the device with the given MAC address and 
  # service token (see class overview for explanation of token).
  #
  def initialize(mac, token)
    @mac, @token = mac, token
    @message = new_message
    @ear_positions = [nil, nil]
  end
  attr_reader :mac, :token
  attr_accessor :voice
  
  #
  # Send all pending messages
  #
  def send
    response = @message.send
    @message = new_message
    return response
  end
  attr_reader :message
  
  #
  # Send a message immediately to get the ear positions.
  #
  def ear_positions
    ear_message = new_message
    ear_message.ears = 'ok'
    ear_message.send
    return ear_message.ear_positions
  end
  
  #
  # Say text.
  #
  def say(text)
    message.tts = text
    message.verifiers["Speech"] = lambda{ |response| response =~ SUCCESS_RESPONSES[:say] }
    nil
  end
  
  #
  # Say text immediately.
  #
  def say!(text)
    say(text)
    send
  end
  
  #
  # Make the rabbit bark.
  #
  def bark
    say('ouah ouah')
    nil
  end

  #
  # Bark immediately.
  #
  def bark!
    bark
    send
  end
  
  #
  # Set the position of the left and right ears between 0 and 16. Use nil to avoid moving an ear.
  # Note that these positions are not given in degrees, and that it is not possible to specify the 
  # direction of movement. For more precise ear control, use choreography instead.
  #
  def move_ears(left, right)
    message.posleft = left if left
    message.posright = right if right
    if left
      message.verifiers["Left ear"] = lambda{ |response| response =~ SUCCESS_RESPONSES[:left_ear] }
    end
    if right
      message.verifiers["Right ear"] = lambda{ |response| response =~ SUCCESS_RESPONSES[:right_ear] }
    end
    return nil
  end
  
  #
  # Move ears immediately.
  #
  def move_ears!(left, right)
    move_ears(left, right)
    send
  end
    
  #
  # Creates a new choreography message based on the actions instructed in the block. The commands 
  # are evaluated in the context of a new Choreography instance.
  #
  # E.g.
  #  nabaztag.choreography do
  #    event { led :middle, :green ; led :left, :red }
  #    led :right, :yellow
  #    event { led :left, :off ; led :right, :off}
  #    ...
  #  end
  #
  def choreography(title=nil, &blk)
    message.chortitle = title
    obj = Choreography.new
    obj.instance_eval(&blk)
    message.chor = obj.emit
    message.verifiers["Choreography"] = lambda{ |response| response =~ SUCCESS_RESPONSES[:choreography] }
    nil
  end
  
  #
  # Creates choreography and sends it immediately.
  #
  def choreography!(title=nil, &blk)
    choreography(title, &blk)
    send
  end
    
  private
  
  def new_message
    return Message.new(self)
  end
  
  #
  # Choreography class uses class methods to implement a simple DSL. These build API choreography 
  # messages based on instructions to move the ears and light the LEDs.
  #
  class Choreography
    
    LED_COLORS = {
      :red          => [255,   0,   0],
      :orange       => [255, 127,   0],
      :yellow       => [255, 255,   0],
      :green        => [  0, 255,   0],
      :blue         => [  0,   0, 255],
      :purple       => [255,   0, 255],
      :dim_red      => [127,   0,   0],
      :dim_orange   => [127,  63,   0],
      :dim_yellow   => [127, 127,   0],
      :dim_green    => [  0, 127,   0],
      :dim_blue     => [  0,   0, 127],
      :dim_purple   => [127,   0, 127],
      :off          => [  0,   0,   0]
    }
    EARS = {:left => [1], :right => [0], :both => [0,1]}
    LEDS = {:bottom => 0, :left => 1, :middle => 2, :right => 3, :top => 4}
    EAR_DIRECTIONS = {:forward => 0, :backward => 1}
    
    def emit
      @messages ||= []
      return (['%d' % (@tempo || 10)] + (@messages || []) ).join(',')
    end
    
    #
    # Set the tempo of the choreography in Hz (i.e. events per secod). The default is 10
    # events per second.
    #
    def tempo(t)
      @tempo = t
    end
  
    #
    # Move :left, :right, or :both ears to angle degrees (0-180) in direction 
    # :forward (default) or :backward.
    #
    def ear(which_ear, angle, direction=:forward)
      direction_number = EAR_DIRECTIONS[direction]
      EARS[which_ear].each do |ear_number|
        append_message('motor', ear_number, angle, 0, direction)
      end
      skip 1
    end
  
    #
    # Change colour of an led (:top, :right:, middle, :left, :bottom) to a specified colour.
    # The colour may be specified either as RGB values (0-255) or by using one of the named colours 
    # in LED_COLORS.
    #
    # E.g. 
    #  led :middle, :red
    #  led :top, 0, 0, 255
    #  led :bottom, :off
    #
    def led(which_led, c1, c2=nil, c3=nil)
      led_number = LEDS[which_led]
      if (c1 && c2 && c3)
        red, green, blue = c1, c2, c3
      else
        red, green, blue = LED_COLORS[c1]
      end
      append_message('led', led_number, red, green, blue)
      skip 1
    end
  
    #
    # Group several actions into a single chronological step via a block.
    #
    # E.g.
    #  event { led :top, :yellow ; ear :both, 0 }
    #
    def event(&blk)
      length(1, &blk)
    end
    
    #
    # Perform one or more actions for n chronological steps
    #
    # E.g.
    #  length 3 do 
    #    led :top, :red ; led :middle, :yellow
    #  end
    #
    def length(duration, &blk)
      old_in_event = @in_event
      @in_event = true
      yield
      @in_event = old_in_event
      skip duration
    end
    
    private
    
    def append_message(*params)
      fields = [@time_stamp || 0] + params
      (@messages ||= []) << ("%d,%s,%d,%d,%d,%d" % fields)
    end

    def skip(duration=1)
      @time_stamp ||= 0
      @time_stamp += duration unless @in_event
    end

  end # Choreography
  
  class Message
    
    FIELDS = [:idmessage, :posright, :posleft, :idapp, :tts, :chor, :chortitle, :nabcast, :ears]
    FIELDS.each do |field|
      attr_accessor field
    end
    
    def initialize(nabaztag)
      @nabaztag = nabaztag
      @verifiers = {}
    end
    attr_reader :verifiers, :ear_positions
    
    def send
      parameters = FIELDS.inject({
        :sn => @nabaztag.mac,
        :token => @nabaztag.token,
        :voice => @nabaztag.voice
      }){ |hash, element|
        value = __send__(element)
        hash[element] = value if value
        hash
      }
      request = build_request(parameters)
      response = Nabaztag.decode_response(open(request).read).split(/\s{2,}/m).join("\n")
      decode_ear_positions(response) if @ears
      verifiers.each do |name, verifier|
        unless verifier.call(response)
          raise ServiceError, "#{name}: #{response}"
        end
      end
      return true
    end
    
    def decode_ear_positions(response)
      left_ear = response[EAR_POSITION_RESPONSES[:left], 1]
      right_ear = response[EAR_POSITION_RESPONSES[:right], 1]
      @ear_positions = [left_ear.to_i, right_ear.to_i] if left_ear && right_ear
    end
    
    private
    
    def build_request(parameters)
      return API_URI << parameters.map{ |k,v| 
        value = CGI.escape(Nabaztag.encode_text(v.to_s))
        "#{k}=#{value}" 
      }.join('&')
    end
    
  end # Message
  
end # Nabaztag
