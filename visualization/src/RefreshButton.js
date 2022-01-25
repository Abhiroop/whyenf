import React from 'react';
import Box from '@mui/material/Box';
import Button from '@mui/material/Button';
import RefreshIcon from '@mui/icons-material/Refresh';

export default class RefreshButton extends React.Component {
  render() {
    return (
        <Button
          variant="contained"
          size="large"
          sx={{
            width: '100%'
          }}
        >
          <Box pt={1}>
            <RefreshIcon color="inherit" />
          </Box>
        </Button>
    );
  }
}
