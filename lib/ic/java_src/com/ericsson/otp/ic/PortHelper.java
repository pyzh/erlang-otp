/* ``The contents of this file are subject to the Erlang Public License,
 * Version 1.1, (the "License"); you may not use this file except in
 * compliance with the License. You should have received a copy of the
 * Erlang Public License along with this software. If not, it can be
 * retrieved via the world wide web at http://www.erlang.org/.
 * 
 * Software distributed under the License is distributed on an "AS IS"
 * basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
 * the License for the specific language governing rights and limitations
 * under the License.
 * 
 * The Initial Developer of the Original Code is Ericsson Utvecklings AB.
 * Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
 * AB. All Rights Reserved.''
 * 
 *     $Id$
 */
package com.ericsson.otp.ic;

/**
  Helper class for Port.
  **/

public class PortHelper {

  // constructors
  private PortHelper() {}
  
  // methods

  /**
    Marshal method for the Port class, encodes the Port object to the output stream.
    **/
  public static void marshal(com.ericsson.otp.erlang.OtpOutputStream _out, Port _value)
    throws java.lang.Exception {
      
      _out.write_port(_value.node(),_value.id(),_value.creation());
  }

  /**
    Unmarshal method for the Port class, decodes a Port object from the stream.
    @return Port, read from the input stream
    **/
  public static Port unmarshal(com.ericsson.otp.erlang.OtpInputStream _in)
    throws java.lang.Exception {
      
      // Double job is done here, there should be 
      // a function returning a Port instead of an
      // OtpErlangPort
      com.ericsson.otp.erlang.OtpErlangPort oep = _in.read_port(); 
      
      return new Port(oep.node(),oep.id(),oep.creation());      
  }
  
  /**
    Standard method that returns the interface repository identity.
    @return String containing the interface repository identity of Port
    **/
  public static String id() {
    return "IDL:com/ericsson/otp/ic/Port:1.0";
  }
  
  /**
    Standard method that returns the Port class name.
    @return String containing the class name of Port
    **/  
  public static String name() {
    return "Port";
  }
  
  /**
    Holds the TypeCode
    **/
  private static com.ericsson.otp.ic.TypeCode _tc;
  
  /**
    Standard TypeCode accessor method.
    @return the TypeCode for Port
    **/
  synchronized public static com.ericsson.otp.ic.TypeCode type() {
    
    if (_tc != null)
      return _tc;
    
     com.ericsson.otp.ic.TypeCode _tc0 =
       new com.ericsson.otp.ic.TypeCode();
     _tc0.kind(com.ericsson.otp.ic.TCKind.tk_struct);
     _tc0.id("IDL:com/ericsson/otp/ic/Port:1.0");
     _tc0.name("Port");
     _tc0.member_count(3);
     _tc0.member_name(0,"node");
     com.ericsson.otp.ic.TypeCode _tc1 =
       new com.ericsson.otp.ic.TypeCode();
     _tc1.kind(com.ericsson.otp.ic.TCKind.tk_string);
     _tc1.length(256);
     _tc0.member_type(0,_tc1);
     _tc0.member_name(1,"id");
     com.ericsson.otp.ic.TypeCode _tc2 =
       new com.ericsson.otp.ic.TypeCode();
     _tc2.kind(com.ericsson.otp.ic.TCKind.tk_ulong);
     _tc0.member_type(1,_tc2);
     _tc0.member_name(2,"creation");
     com.ericsson.otp.ic.TypeCode _tc3 =
       new com.ericsson.otp.ic.TypeCode();
     _tc3.kind(com.ericsson.otp.ic.TCKind.tk_ulong);
     _tc0.member_type(2,_tc3);

     _tc = _tc0;

     return _tc0;
   }


  /**
    Standard method for inserting a Port to an Any.
    **/
   public static void insert(com.ericsson.otp.ic.Any _any, Port _this)
     throws java.lang.Exception {

     com.ericsson.otp.erlang.OtpOutputStream _os = 
       new com.ericsson.otp.erlang.OtpOutputStream();

     _any.type(type());
     marshal(_os, _this);
     _any.insert_Streamable(_os);
   }

  /**
    Standard method for extracting a Port from an Any.
    @return Port, the value found in an Any contained stream.
    **/
   public static Port extract(com.ericsson.otp.ic.Any _any)
     throws java.lang.Exception {

     return unmarshal(_any.extract_Streamable());
   }

}
