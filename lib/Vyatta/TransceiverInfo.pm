#
# Module: Vyatta::TransceiverInfo.pm
#
# Copyright (c) 2018-2020, AT&T Intellectual Property.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#

package Vyatta::TransceiverInfo;

use strict;
use warnings;
use JSON;
use POSIX qw(log10);
use Vyatta::Dataplane qw(vplane_exec_cmd);

use constant QSFP_CHANNELS => 4;

sub convert_mW_2_dbm {
    my ($mW) = @_;

    # If no power, return empty string since log(0) = Inf.
    if ( $mW == 0 ) {
        return 0;
    }

    my $dbm = 10 * log10($mW);
    $dbm = sprintf( "%.4f", $dbm );
    return $dbm;
}

#
# Get port Transceiver Info
#
sub get_transceiver_info {
    my ( $port_name, $objref ) = @_;
    my %params = %{$objref};

    my ( $dpids, $dpsocks ) = Vyatta::Dataplane::setup_fabric_conns();

    my $resp = vplane_exec_cmd( "ifconfig -v $port_name", $dpids, $dpsocks, 1 );

    # Decode the response from each vplane
    for my $dpid ( @{$dpids} ) {
        next unless defined( $resp->[$dpid] );
        my $decoded = decode_json( $resp->[$dpid] );
        next unless defined( $decoded->{'interfaces'} );
        my $interface = $decoded->{'interfaces'}[0];

        my $xcvr_info = $interface->{'xcvr_info'};
        next unless defined $xcvr_info;
        my $identifier = $xcvr_info->{'identifier'};
        $params{'form-factor'}         = $xcvr_info->{'identifier'};
        $params{'connector-type'}      = $xcvr_info->{'connector'};
        $params{'ethernet-pmd'}        = $xcvr_info->{'xcvr_class'};
        $params{'vendor'}              = $xcvr_info->{'vendor_name'};
        $params{'vendor-part'}         = $xcvr_info->{'vendor_pn'};
        $params{'serial-no'}           = $xcvr_info->{'vendor_sn'};
        $params{'date-code'}           = $xcvr_info->{'date'};
        $params{'sff-8472-compliance'} = $xcvr_info->{'8472_compl'};
        $params{'nominal-bit-rate'}    = $xcvr_info->{'nominal_bit_rate_mbps'};
        $params{'encoding'}            = $xcvr_info->{'encoding'};

        my %link_len;
        $params{'link-lengths'} = \%link_len;
        $link_len{'smf-km'}     = $xcvr_info->{'smf_km'}
          if defined( $xcvr_info->{'smf_km'} );
        if ( $xcvr_info->{'smf_100'} ) {
            $link_len{'smf'} = $xcvr_info->{'smf_100'};
        } else {
            $link_len{'smf'} = 0;
        }
        $link_len{'um_50'} = $xcvr_info->{'smf_om2'}
          if defined( $xcvr_info->{'smf_om2'} );
        $link_len{'um_625'} = $xcvr_info->{'smf_om1'}
          if defined( $xcvr_info->{'smf_om1'} );
        if ( $xcvr_info->{'copper_len'} ) {
            $link_len{'cable'} = $xcvr_info->{'copper_len'};
        } else {
            $link_len{'cable'} = 0;
        }
        $link_len{'om3'} = $xcvr_info->{'smf_om3'}
          if defined( $xcvr_info->{'smf_om3'} );

        $params{'vendor-oui'} = $xcvr_info->{'vendor_oui'};
        if ( $xcvr_info->{'vendor_rev'} ) {
            $params{'vendor-rev'} = $xcvr_info->{'vendor_rev'};
        } else {
            $params{'vendor-rev'} = " ";
        }
        if ( $xcvr_info->{'diag_type'} ) {
            $params{'diagnostic-monitoring-type'} = $xcvr_info->{'diag_type'};
        } else {
            $params{'diagnostic-monitoring-type'} = 0;
        }
        if ( $xcvr_info->{'ext_identifier'} ) {
            $params{'extended-id'} = $xcvr_info->{'ext_identifier'};
        } else {
            $params{'extended-id'} = " ";
        }

        #Check the diagnostic monitoring type bit 6.
        #If bit not set then don't show the diag info on CLI.
        if ( $identifier eq 'SFP/SFP+/SFP28' ) {
            my $diag_mon_type = $params{'diagnostic-monitoring-type'};
            if ( not $diag_mon_type & ( 1 << 6 ) ) {
                last;
            }
        }

        # Thresholds
        my %temp_thresh;
        $params{'temperature-thresholds'} = \%temp_thresh;

        $temp_thresh{'temperature-high-alarm'} =
          $xcvr_info->{'high_temp_alarm_thresh'}
            if defined($xcvr_info->{'high_temp_alarm_thresh'});
        $temp_thresh{'temperature-low-alarm'} =
          $xcvr_info->{'low_temp_alarm_thresh'}
            if defined($xcvr_info->{'low_temp_alarm_thresh'});
        $temp_thresh{'temperature-high-warning'} =
          $xcvr_info->{'high_temp_warn_thresh'}
            if defined($xcvr_info->{'high_temp_warn_thresh'});
        $temp_thresh{'temperature-low-warning'} =
          $xcvr_info->{'low_temp_warn_thresh'}
            if defined($xcvr_info->{'low_temp_warn_thresh'});

        my %volt_thresh;
        $params{'voltage-thresholds'} = \%volt_thresh;

        $volt_thresh{'voltage-high-alarm'} =
          $xcvr_info->{'high_voltage_alarm_thresh'}
            if defined($xcvr_info->{'high_voltage_alarm_thresh'});
        $volt_thresh{'voltage-low-alarm'} =
          $xcvr_info->{'low_voltage_alarm_thresh'}
            if defined($xcvr_info->{'low_voltage_alarm_thresh'});
        $volt_thresh{'voltage-high-warning'} =
          $xcvr_info->{'high_voltage_warn_thresh'}
            if defined($xcvr_info->{'high_voltage_warn_thresh'});
        $volt_thresh{'voltage-low-warning'} =
          $xcvr_info->{'low_voltage_warn_thresh'}
            if defined($xcvr_info->{'low_voltage_warn_thresh'});

        my %laser_bias_thresh;
        $params{'laser-bias-current-thresholds'} = \%laser_bias_thresh;

        $laser_bias_thresh{'laser-bias-current-high-alarm'} =
          $xcvr_info->{'high_bias_alarm_thresh'}
            if defined($xcvr_info->{'high_bias_alarm_thresh'});
        $laser_bias_thresh{'laser-bias-current-low-alarm'} =
          $xcvr_info->{'low_bias_alarm_thresh'}
            if defined($xcvr_info->{'low_bias_alarm_thresh'});
        $laser_bias_thresh{'laser-bias-current-high-warning'} =
          $xcvr_info->{'high_bias_warn_thresh'}
            if defined($xcvr_info->{'high_bias_warn_thresh'});
        $laser_bias_thresh{'laser-bias-current-low-warning'} =
          $xcvr_info->{'low_bias_warn_thresh'}
            if defined($xcvr_info->{'low_bias_warn_thresh'});

        my %op_power_thresh;
        $params{'output-power-thresholds'} = \%op_power_thresh;

        $op_power_thresh{'output-power-high-alarm'} =
          convert_mW_2_dbm( $xcvr_info->{'high_tx_power_alarm_thresh'} )
            if defined($xcvr_info->{'high_tx_power_alarm_thresh'});
        $op_power_thresh{'output-power-low-alarm'} =
          convert_mW_2_dbm( $xcvr_info->{'low_tx_power_alarm_thresh'} )
            if defined($xcvr_info->{'low_tx_power_alarm_thresh'});
        $op_power_thresh{'output-power-high-warning'} =
          convert_mW_2_dbm( $xcvr_info->{'high_tx_power_warn_thresh'} )
            if defined($xcvr_info->{'high_tx_power_warn_thresh'});
        $op_power_thresh{'output-power-low-warning'} =
          convert_mW_2_dbm( $xcvr_info->{'low_tx_power_warn_thresh'} )
            if defined($xcvr_info->{'low_tx_power_warn_thresh'});

        my %ip_power_thresh;
        $params{'input-power-thresholds'} = \%ip_power_thresh;

        $ip_power_thresh{'input-power-high-alarm'} =
          convert_mW_2_dbm( $xcvr_info->{'high_rx_power_alarm_thresh'})
            if defined($xcvr_info->{'high_rx_power_alarm_thresh'} );
        $ip_power_thresh{'input-power-low-alarm'} =
          convert_mW_2_dbm( $xcvr_info->{'low_rx_power_alarm_thresh'})
            if defined($xcvr_info->{'low_rx_power_alarm_thresh'} );
        $ip_power_thresh{'input-power-high-warning'} =
          convert_mW_2_dbm( $xcvr_info->{'high_rx_power_warn_thresh'})
            if defined($xcvr_info->{'high_rx_power_warn_thresh'} );
        $ip_power_thresh{'input-power-low-warning'} =
          convert_mW_2_dbm( $xcvr_info->{'low_rx_power_warn_thresh'})
            if defined($xcvr_info->{'low_rx_power_warn_thresh'});

        #Alarm flags
        my %alm_status;
        $alm_status{'temperature-high-alarm'} = $xcvr_info->{'temp_high_alarm'}
          if defined( $xcvr_info->{'temp_high_alarm'} );
        $alm_status{'temperature-low-alarm'} = $xcvr_info->{'temp_low_alarm'}
          if defined( $xcvr_info->{'temp_low_alarm'} );
        $alm_status{'voltage-high-alarm'} = $xcvr_info->{'vcc_high_alarm'}
          if defined( $xcvr_info->{'vcc_high_alarm'} );
        $alm_status{'voltage-low-alarm'} = $xcvr_info->{'vcc_low_alarm'}
          if defined( $xcvr_info->{'vcc_low_alarm'} );

        #Warning flags
        my %warn_status;
        $warn_status{'temperature-high-warning'} =
          $xcvr_info->{'temp_high_warn'}
          if defined( $xcvr_info->{'temp_high_warn'} );
        $warn_status{'temperature-low-warning'} = $xcvr_info->{'temp_low_warn'}
          if defined( $xcvr_info->{'temp_low_warn'} );
        $warn_status{'voltage-high-warning'} = $xcvr_info->{'vcc_high_warn'}
          if defined( $xcvr_info->{'vcc_high_warn'} );
        $warn_status{'voltage-low-warning'} = $xcvr_info->{'vcc_low_warn'}
          if defined( $xcvr_info->{'vcc_low_warn'} );


        my @channels = ();

        if ( $identifier eq "QSFP+" || $identifier eq "QSFP28" ) {
            my @measured_val = @{ $xcvr_info->{'measured_values'} };
            my @alarm_warn   = @{ $xcvr_info->{'alarm_warning'} };

            for ( my $ch = 0 ; $ch < QSFP_CHANNELS ; $ch++ ) {

                #Measured Values
                my $output_power =
                  convert_mW_2_dbm( $measured_val[$ch]->{'tx_power_mW'} )
                  if defined( $measured_val[$ch]->{'tx_power_mW'} );
                my $input_power =
                  convert_mW_2_dbm( $measured_val[$ch]->{'rx_power_mW'} )
                  if defined( $measured_val[$ch]->{'rx_power_mW'} );
                my $laser_bias = $measured_val[$ch]->{'laser_bias'}
                  if defined( $measured_val[$ch]->{'laser_bias'} );

                #Channel Alarm flags
                my $bias_high = $alarm_warn[$ch]->{'tx_bias_high_alarm'}
                  if defined( $alarm_warn[$ch]->{'tx_bias_high_alarm'} );
                my $bias_low = $alarm_warn[$ch]->{'tx_bias_low_alarm'}
                  if defined( $alarm_warn[$ch]->{'tx_bias_low_alarm'} );
                my $op_pow_high = $alarm_warn[$ch]->{'tx_power_high_alarm'}
                  if defined( $alarm_warn[$ch]->{'tx_power_high_alarm'} );
                my $op_pow_low = $alarm_warn[$ch]->{'tx_power_low_alarm'}
                  if defined( $alarm_warn[$ch]->{'tx_power_low_alarm'} );
                my $ip_pow_high = $alarm_warn[$ch]->{'rx_power_high_alarm'}
                  if defined( $alarm_warn[$ch]->{'rx_power_high_alarm'} );
                my $ip_pow_low = $alarm_warn[$ch]->{'rx_power_low_alarm'}
                  if defined( $alarm_warn[$ch]->{'rx_power_low_alarm'} );

                #Channel Warning flags
                my $bias_high_warn = $alarm_warn[$ch]->{'tx_bias_high_warn'}
                  if defined( $alarm_warn[$ch]->{'tx_bias_high_warn'} );
                my $bias_low_warn = $alarm_warn[$ch]->{'tx_bias_low_warn'}
                  if defined( $alarm_warn[$ch]->{'tx_bias_low_warn'} );
                my $op_pow_high_warn = $alarm_warn[$ch]->{'tx_power_high_warn'}
                  if defined( $alarm_warn[$ch]->{'tx_power_high_warn'} );
                my $op_pow_low_warn = $alarm_warn[$ch]->{'tx_power_low_warn'}
                  if defined( $alarm_warn[$ch]->{'tx_power_low_warn'} );
                my $ip_pow_high_warn = $alarm_warn[$ch]->{'rx_power_high_warn'}
                  if defined( $alarm_warn[$ch]->{'rx_power_high_warn'} );
                my $ip_pow_low_warn = $alarm_warn[$ch]->{'rx_power_low_warn'}
                  if defined( $alarm_warn[$ch]->{'rx_power_low_warn'} );

                my $alm_status = {
                    'bias-current-high-alarm' => $bias_high,
                    'bias-current-low-alarm'  => $bias_low,
                    'output-power-high-alarm' => $op_pow_high,
                    'output-power-low-alarm'  => $op_pow_low,
                    'input-power-high-alarm'  => $ip_pow_high,
                    'input-power-low-alarm'   => $ip_pow_low,
                };

                my $warn_status = {
                    'bias-current-high-warning' => $bias_high_warn,
                    'bias-current-low-warning'  => $bias_low_warn,
                    'output-power-high-warning' => $op_pow_high_warn,
                    'output-power-low-warning'  => $op_pow_low_warn,
                    'input-power-high-warning'  => $ip_pow_high_warn,
                    'input-power-low-warning'   => $ip_pow_low_warn,
                };

                my $index = {
                    'index'              => $ch,
                    'output-power'       => $output_power,
                    'input-power'        => $input_power,
                    'laser-bias-current' => $laser_bias,
                    'alarm-status'       => $alm_status,
                    'warning-status'     => $warn_status,
                };

                push( @channels, $index );
            }
        } else {

            #Measured Values
            my $output_power = convert_mW_2_dbm( $xcvr_info->{'tx_power_mW'} )
                 if defined( $xcvr_info->{'tx_power_mW'} );
            my $input_power = convert_mW_2_dbm( $xcvr_info->{'rx_power_mW'} )
                 if defined( $xcvr_info->{'rx_power_mW'} );
            my $laser_bias = $xcvr_info->{'laser_bias'}
                 if defined( $xcvr_info->{'laser_bias'} );

            #Alarm flags
            my $bias_high = $xcvr_info->{'tx_bias_high_alarm'}
              if defined( $xcvr_info->{'tx_bias_high_alarm'} );
            my $bias_low = $xcvr_info->{'tx_bias_low_alarm'}
              if defined( $xcvr_info->{'tx_bias_low_alarm'} );
            my $op_pow_high = $xcvr_info->{'tx_power_high_alarm'}
              if defined( $xcvr_info->{'tx_power_high_alarm'} );
            my $op_pow_low = $xcvr_info->{'tx_power_low_alarm'}
              if defined( $xcvr_info->{'tx_power_low_alarm'} );
            my $ip_pow_high = $xcvr_info->{'rx_power_high_alarm'}
              if defined( $xcvr_info->{'rx_power_high_alarm'} );
            my $ip_pow_low = $xcvr_info->{'rx_power_low_alarm'}
              if defined( $xcvr_info->{'rx_power_low_alarm'} );

            #Warning flags
            my $bias_high_warn = $xcvr_info->{'tx_bias_high_warn'}
              if defined( $xcvr_info->{'tx_bias_high_warn'} );
            my $bias_low_warn = $xcvr_info->{'tx_bias_low_warn'}
              if defined( $xcvr_info->{'tx_bias_low_warn'} );
            my $op_pow_high_warn = $xcvr_info->{'tx_power_high_warn'}
              if defined( $xcvr_info->{'tx_power_high_warn'} );
            my $op_pow_low_warn = $xcvr_info->{'tx_power_low_warn'}
              if defined( $xcvr_info->{'tx_power_low_warn'} );
            my $ip_pow_high_warn = $xcvr_info->{'rx_power_high_warn'}
              if defined( $xcvr_info->{'rx_power_high_warn'} );
            my $ip_pow_low_warn = $xcvr_info->{'rx_power_low_warn'}
              if defined( $xcvr_info->{'rx_power_low_warn'} );

            my $alm_status = {
                'bias-current-high-alarm' => $bias_high,
                'bias-current-low-alarm'  => $bias_low,
                'output-power-high-alarm' => $op_pow_high,
                'output-power-low-alarm'  => $op_pow_low,
                'input-power-high-alarm'  => $ip_pow_high,
                'input-power-low-alarm'   => $ip_pow_low,
            };

            my $warn_status = {
                'bias-current-high-warning' => $bias_high_warn,
                'bias-current-low-warning'  => $bias_low_warn,
                'output-power-high-warning' => $op_pow_high_warn,
                'output-power-low-warning'  => $op_pow_low_warn,
                'input-power-high-warning'  => $ip_pow_high_warn,
                'input-power-low-warning'   => $ip_pow_low_warn,
            };

            my $index = {
                'index'              => 0,
                'output-power'       => $output_power,
                'input-power'        => $input_power,
                'laser-bias-current' => $laser_bias,
                'alarm-status'       => $alm_status,
                'warning-status'     => $warn_status,
            };

            push( @channels, $index );
        }

        my %phy_channels;
        $params{'physical-channels'} = \%phy_channels;

        $phy_channels{'channel'}        = \@channels;
        $phy_channels{'alarm-status'}   = \%alm_status;
        $phy_channels{'warning-status'} = \%warn_status;

        # Measured Values
        $params{'internal-temp'} = $xcvr_info->{'temperature_C'}
          if defined( $xcvr_info->{'temperature_C'} );
        $params{'voltage'} = $xcvr_info->{'voltage_V'}
          if defined( $xcvr_info->{'voltage_V'} );

    }
    Vyatta::Dataplane::close_fabric_conns( $dpids, $dpsocks );

    my $output = { 'transceiver-info' => \%params, };

    return $output;
}

#
# $port = Vyatta::TransceiverInfo->new($port_name);
#
sub new {
    my ( $class, $port_name, $debug ) = @_;
    my $objref = {};

    $objref = get_transceiver_info( $port_name, $objref );

    bless $objref, $class;
    return $objref;
}

1;
