import React from 'react';
import Box from '@mui/material/Box';
import Button from '@mui/material/Button'
import ClearAllIcon from '@mui/icons-material/ClearAll';

export default function ResetButton ({ handleReset }) {
  return (
    <Button
      variant="contained"
      size="large"
      sx={{
        width: '100%'
      }}
      onClick={handleReset}
    >
      <Box pt={1}>
        <ClearAllIcon color="inherit" />
      </Box>
    </Button>
  );
}
